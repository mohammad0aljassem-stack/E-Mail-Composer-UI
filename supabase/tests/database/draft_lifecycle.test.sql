-- ============================================================================
-- Phase 2 database tests — draft lifecycle (SECURITY DEFINER RPC + triggers)
--
-- Plain-SQL tests (no pgTAP). Run with:  psql -v ON_ERROR_STOP=1 -f <this>
-- against a database that has the baseline + the amended Phase 2 migration
-- applied. Any uncaught exception makes psql exit non-zero, which the runner
-- reports as FAIL. Each passing assertion emits: NOTICE ok - <message>.
--
-- The Phase 2 tables are now SELECT-only for authenticated (drafts,
-- draft_versions, draft_template_versions, draft_attachments), so every
-- mutation goes through a SECURITY DEFINER RPC whose signature now carries an
-- explicit p_workspace_id the function cross-checks against the target row.
--
-- PostgREST request simulation: SET LOCAL ROLE authenticated/anon plus a
-- transaction-local request.jwt.claims GUC, exactly like Supabase does.
-- Seeding and clock manipulation run as the superuser.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Harness helpers (superuser)
-- ---------------------------------------------------------------------------
create or replace function public.test_assert(p_cond boolean, p_msg text)
returns void
language plpgsql
as $$
begin
  if p_cond is distinct from true then
    raise exception 'ASSERT FAILED: %', p_msg using errcode = 'ASSRT';
  end if;
  raise notice 'ok - %', p_msg;
end;
$$;
grant execute on function public.test_assert(boolean, text) to public;

create or replace function public.test_doc(p_text text)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'type', 'doc',
    'content', jsonb_build_array(
      jsonb_build_object(
        'type', 'paragraph',
        'content', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', p_text)))));
$$;
grant execute on function public.test_doc(text) to public;

-- ---------------------------------------------------------------------------
-- Seed users/workspaces (superuser; idempotent)
--   A = 1111... and B = 2222... are members of W1 = aaaa...
--   C = 3333... is a member of W2 = bbbb...
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '{"full_name":"Alice"}'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com', '{"full_name":"Bob"}'),
  ('33333333-3333-3333-3333-333333333333', 'carol@example.com', '{"full_name":"Carol"}')
on conflict (id) do nothing;

insert into public.workspaces (id, name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Workspace One'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Workspace Two')
on conflict (id) do nothing;

insert into public.workspace_members (workspace_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', 'member'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '33333333-3333-3333-3333-333333333333', 'owner')
on conflict (workspace_id, user_id) do nothing;

-- ---------------------------------------------------------------------------
-- Scenarios (single transaction, rolled back at the end)
-- ---------------------------------------------------------------------------
begin;

create temporary table t_ctx (key text primary key, val text) on commit drop;
grant all on table t_ctx to public;

-- ===== act as user A (member of W1) =====
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;

-- 1. create_draft: draft + initial version
do $$
declare
  d public.drafts;
  v public.draft_versions;
begin
  d := public.create_draft(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'Kickoff email',
    public.test_doc('original body'));
  perform public.test_assert(d.id is not null, 'create_draft returns the inserted draft');
  perform public.test_assert(d.revision = 1, 'new draft starts at revision 1');
  perform public.test_assert(d.status = 'draft', 'new draft has status draft');
  perform public.test_assert(
    d.created_by = auth.uid() and d.updated_by = auth.uid(),
    'create_draft stamps created_by/updated_by with auth.uid()');

  select * into v from public.draft_versions where draft_id = d.id;
  perform public.test_assert(
    v.version_no = 1 and v.reason = 'initial' and v.source_revision = 1,
    'create_draft writes exactly one initial version (version_no 1)');
  perform public.test_assert(
    v.subject = d.subject and v.body_json = d.body_json and v.workspace_id = d.workspace_id,
    'initial version snapshots the draft content');

  insert into t_ctx values ('draft_a', d.id::text);
end $$;

-- 1b. create_draft rejects a workspace the caller is not a member of (P0002)
do $$
begin
  begin
    perform public.create_draft('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'x', public.test_doc('x'));
    raise exception 'create_draft accepted a foreign workspace' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'create_draft raises P0002 for a non-member workspace');
  end;
end $$;

-- 2. save_draft happy path bumps revision (no fresh checkpoint needed)
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  r jsonb;
  n bigint;
begin
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1, 'Kickoff email', public.test_doc('body v2'), 'autosave');
  perform public.test_assert((r ->> 'revision')::bigint = 2, 'save_draft bumps revision to 2');
  perform public.test_assert((r ->> 'last_autosaved_at') is not null, 'save_draft sets last_autosaved_at');
  perform public.test_assert(
    (r ->> 'version_created')::boolean = false,
    'autosave right after the initial version does not create a checkpoint');
  select count(*) into n from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n = 1, 'version count unchanged after young autosave');
end $$;

-- 3. identical-content save is a no-op
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  r jsonb;
  n bigint;
begin
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2, 'Kickoff email', public.test_doc('body v2'), 'autosave');
  perform public.test_assert((r ->> 'revision')::bigint = 2, 'identical save keeps revision at 2');
  perform public.test_assert((r ->> 'version_created')::boolean = false, 'identical save creates no version');
  select count(*) into n from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n = 1, 'identical save leaves version history untouched');
end $$;

-- 4. wrong expected revision raises SQLSTATE P0409 WITH the current_revision hint
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  v_hint text;
begin
  begin
    perform public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 99, 'x', public.test_doc('x'), 'manual_checkpoint');
    raise exception 'save_draft accepted a stale revision' using errcode = 'ASSRT';
  exception when sqlstate 'P0409' then
    get stacked diagnostics v_hint = pg_exception_hint;
    perform public.test_assert(true, 'stale expected_revision raises SQLSTATE P0409');
    perform public.test_assert(
      v_hint = 'current_revision=2',
      'P0409 carries hint current_revision=2 (the actual current revision)');
  end;
end $$;

-- 5. invalid save reasons are rejected
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
begin
  begin
    perform public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2, 'x', public.test_doc('x'), 'restore');
    raise exception 'save_draft accepted reason restore' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'save_draft rejects reason ''restore'' (22023)');
  end;
  begin
    perform public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2, 'x', public.test_doc('x'), 'initial');
    raise exception 'save_draft accepted reason initial' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'save_draft rejects reason ''initial'' (22023)');
  end;
end $$;

-- 5b. cross-workspace guards: mismatched p_workspace_id and non-member caller
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
begin
  -- Correct draft, but the client claims the wrong workspace -> P0002.
  begin
    perform public.save_draft(v_draft, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 2, 'x', public.test_doc('x'), 'autosave');
    raise exception 'save_draft accepted a workspace_id mismatch' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'save_draft rejects a client workspace_id that does not match the draft (P0002)');
  end;
end $$;

-- ===== act as user C (member of W2, NOT W1) to prove cross-tenant denial =====
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
begin
  begin
    perform public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2, 'x', public.test_doc('x'), 'autosave');
    raise exception 'non-member C mutated a W1 draft' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'a non-member (W2 user on a W1 draft) is denied by save_draft (P0002)');
  end;
  begin
    perform public.archive_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2);
    raise exception 'non-member C archived a W1 draft' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'a non-member is denied by archive_draft (P0002)');
  end;
end $$;

-- ===== back to user A =====
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

-- 6. autosave checkpoint policy: simulate 11 minutes passing (superuser
--    backdates the history; the immutability trigger must be disabled for it)
reset role;
alter table public.draft_versions disable trigger trg_draft_versions_immutable;
update public.draft_versions
set created_at = created_at - interval '11 minutes'
where draft_id = (select val from t_ctx where key = 'draft_a')::uuid;
alter table public.draft_versions enable trigger trg_draft_versions_immutable;
set local role authenticated;

do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  r jsonb;
  v public.draft_versions;
begin
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 2, 'Kickoff email', public.test_doc('body v3'), 'autosave');
  perform public.test_assert((r ->> 'revision')::bigint = 3, 'autosave after 10-minute window bumps revision to 3');
  perform public.test_assert(
    (r ->> 'version_created')::boolean = true,
    'autosave creates a checkpoint once the newest version is older than 10 minutes');

  select * into v from public.draft_versions
  where draft_id = v_draft order by version_no desc limit 1;
  perform public.test_assert(
    v.version_no = 2 and v.reason = 'autosave_checkpoint' and v.source_revision = 3,
    'autosave checkpoint stored as version 2 with reason autosave_checkpoint');

  -- a second autosave immediately after must NOT duplicate the checkpoint
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 3, 'Kickoff email', public.test_doc('body v4'), 'autosave');
  perform public.test_assert(
    (r ->> 'revision')::bigint = 4 and (r ->> 'version_created')::boolean = false,
    'autosave within 10 minutes of a fresh checkpoint is not duplicated');
end $$;

-- 7. manual_checkpoint reason always versions
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  r jsonb;
  v public.draft_versions;
begin
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 4, 'Kickoff email', public.test_doc('body v5'), 'manual_checkpoint');
  perform public.test_assert(
    (r ->> 'revision')::bigint = 5 and (r ->> 'version_created')::boolean = true,
    'save with reason manual_checkpoint always creates a version');
  select * into v from public.draft_versions
  where draft_id = v_draft order by version_no desc limit 1;
  perform public.test_assert(
    v.version_no = 3 and v.reason = 'manual_checkpoint',
    'manual checkpoint stored as version 3');
end $$;

-- 7b. save_draft records the template/signature trace pointers server-side
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  r jsonb;
  d public.drafts;
  v_tv uuid := gen_random_uuid();
  v_sig uuid := gen_random_uuid();
begin
  -- identical content + pointers: no revision bump, but pointers are persisted.
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 5, 'Kickoff email', public.test_doc('body v5'),
    'after_template', v_tv, v_sig);
  perform public.test_assert((r ->> 'revision')::bigint = 5, 'pointer-only save on identical content does not bump revision');
  select * into d from public.drafts where id = v_draft;
  perform public.test_assert(
    d.last_template_version_id = v_tv and d.last_signature_id = v_sig,
    'save_draft persists last_template_version_id / last_signature_id pointers');
end $$;

-- 8. checkpoint_draft dedupes identical snapshots and validates input
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  r jsonb;
begin
  r := public.checkpoint_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 5, 'manual_checkpoint');
  perform public.test_assert(
    (r ->> 'version_created')::boolean = false and (r ->> 'version_no')::bigint = 3,
    'checkpoint_draft skips a snapshot identical to the latest version');

  begin
    perform public.checkpoint_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 5, 'after_template');
    raise exception 'checkpoint_draft accepted reason after_template' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'checkpoint_draft rejects reason ''after_template'' (22023)');
  end;

  begin
    perform public.checkpoint_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 42, 'manual_checkpoint');
    raise exception 'checkpoint_draft accepted a stale revision' using errcode = 'ASSRT';
  exception when sqlstate 'P0409' then
    perform public.test_assert(true, 'checkpoint_draft raises P0409 on stale revision');
  end;

  -- change content (young checkpoint -> autosave writes no version), then checkpoint
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 5, 'Kickoff email', public.test_doc('body v6'), 'autosave');
  perform public.test_assert(
    (r ->> 'revision')::bigint = 6 and (r ->> 'version_created')::boolean = false,
    'autosave after manual checkpoint stays within the 10-minute window');
  r := public.checkpoint_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 6, 'before_template');
  perform public.test_assert(
    (r ->> 'version_created')::boolean = true and (r ->> 'version_no')::bigint = 4,
    'checkpoint_draft snapshots changed content as version 4 (before_template)');
end $$;

-- 9. restore_draft_version: clean state (current content already snapshotted)
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  v1 public.draft_versions;
  d public.drafts;
  r jsonb;
  n bigint;
begin
  select * into v1 from public.draft_versions where draft_id = v_draft and version_no = 1;

  begin
    perform public.restore_draft_version(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v1.id, 5);
    raise exception 'restore accepted a stale revision' using errcode = 'ASSRT';
  exception when sqlstate 'P0409' then
    perform public.test_assert(true, 'restore_draft_version raises P0409 on stale revision');
  end;

  r := public.restore_draft_version(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v1.id, 6);
  perform public.test_assert((r ->> 'revision')::bigint = 7, 'restore bumps revision to 7');
  perform public.test_assert(
    (r ->> 'restored_from_version_no')::bigint = 1,
    'restore reports the source version_no');

  select * into d from public.drafts where id = v_draft;
  perform public.test_assert(
    d.subject = v1.subject and d.body_json = v1.body_json,
    'restore copies the historical subject/body into the draft');

  select count(*) into n from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n = 5, 'restore appended one version (no pre-checkpoint: state was clean)');
  perform public.test_assert(
    (select reason from public.draft_versions where draft_id = v_draft order by version_no desc limit 1) = 'restore',
    'newest version has reason restore');
  perform public.test_assert(
    exists (select 1 from public.draft_versions where draft_id = v_draft and version_no = 4),
    'pre-restore history is preserved');
end $$;

-- 10. restore_draft_version: dirty state checkpoints first; version numbering strictly increasing
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  v2 public.draft_versions;
  d public.drafts;
  r jsonb;
  n bigint;
begin
  -- dirty the draft (fresh history -> autosave writes no version)
  r := public.save_draft(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 7, 'Dirty subject', public.test_doc('dirty body'), 'autosave');
  perform public.test_assert(
    (r ->> 'revision')::bigint = 8 and (r ->> 'version_created')::boolean = false,
    'draft dirtied without a checkpoint');

  select * into v2 from public.draft_versions where draft_id = v_draft and version_no = 2;
  r := public.restore_draft_version(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v2.id, 8);
  perform public.test_assert((r ->> 'revision')::bigint = 9, 'dirty restore bumps revision to 9');

  select count(*) into n from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n = 7, 'dirty restore wrote a pre-checkpoint plus the restore version');
  perform public.test_assert(
    (select reason from public.draft_versions where draft_id = v_draft and version_no = 6) = 'manual_checkpoint'
    and (select subject from public.draft_versions where draft_id = v_draft and version_no = 6) = 'Dirty subject',
    'unsaved state was checkpointed before restoring');
  perform public.test_assert(
    (select reason from public.draft_versions where draft_id = v_draft and version_no = 7) = 'restore',
    'restore version appended last');

  select * into d from public.drafts where id = v_draft;
  perform public.test_assert(d.subject = v2.subject and d.body_json = v2.body_json,
    'dirty restore copied version 2 content');

  perform public.test_assert(
    (select max(version_no) = count(*) and count(distinct version_no) = count(*)
     from public.draft_versions where draft_id = v_draft),
    'version numbering is strictly increasing without gaps or duplicates');
end $$;

-- 11. restore rejects versions of other drafts; content constraints hold
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  d2 public.drafts;
  v_other uuid;
begin
  d2 := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Other draft', public.test_doc('other'));
  insert into t_ctx values ('draft_b', d2.id::text);
  select id into v_other from public.draft_versions where draft_id = d2.id and version_no = 1;

  begin
    perform public.restore_draft_version(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_other, 9);
    raise exception 'restore accepted a foreign version' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'restore rejects a version belonging to another draft (P0002)');
  end;

  begin
    perform public.save_draft(d2.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1, repeat('s', 501), public.test_doc('x'), 'autosave');
    raise exception 'subject over 500 chars was accepted' using errcode = 'ASSRT';
  exception when check_violation then
    perform public.test_assert(true, 'subject longer than 500 chars violates the CHECK constraint');
  end;

  begin
    perform public.save_draft(d2.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1, 'big', public.test_doc(repeat('x', 1100000)), 'autosave');
    raise exception 'body over 1 MiB was accepted' using errcode = 'ASSRT';
  exception when check_violation then
    perform public.test_assert(true, 'body_json larger than 1 MiB violates the CHECK constraint');
  end;

  begin
    perform public.save_draft(d2.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1, 'not a doc', '{"type":"paragraph"}'::jsonb, 'autosave');
    raise exception 'non-doc body was accepted' using errcode = 'ASSRT';
  exception when check_violation then
    perform public.test_assert(true, 'body_json without type=doc violates the CHECK constraint');
  end;
end $$;

-- 11b. archive_draft: happy path, idempotency, optimistic concurrency
do $$
declare
  d public.drafts;
  r jsonb;
begin
  d := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'To archive', public.test_doc('bye'));
  r := public.archive_draft(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', d.revision);
  perform public.test_assert(
    (r ->> 'status') = 'archived' and (r ->> 'archived_at') is not null,
    'archive_draft marks the draft archived and stamps archived_at');
  perform public.test_assert((r ->> 'revision')::bigint = d.revision + 1, 'archive_draft bumps the revision');

  -- idempotent: archiving again at the new revision is a no-op that still reports archived
  r := public.archive_draft(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', (r ->> 'revision')::bigint);
  perform public.test_assert((r ->> 'status') = 'archived', 'archive_draft is idempotent for an already-archived draft');

  begin
    perform public.archive_draft(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1);
    raise exception 'archive accepted a stale revision' using errcode = 'ASSRT';
  exception when sqlstate 'P0409' then
    perform public.test_assert(true, 'archive_draft raises P0409 on a stale revision');
  end;
end $$;

-- 12. create_template_version increments version_no and validates the schema
do $$
declare
  t_id uuid;
  tv public.draft_template_versions;
begin
  insert into public.draft_templates (workspace_id, name, description, created_by)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Welcome template', 'first template', auth.uid())
  returning id into t_id;
  insert into t_ctx values ('template_a', t_id::text);

  tv := public.create_template_version(
    t_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Hello {{first_name}}', public.test_doc('template body v1'),
    '[{"key":"first_name","label":"First name","required":true}]'::jsonb);
  perform public.test_assert(tv.version_no = 1, 'first template version gets version_no 1');
  perform public.test_assert(tv.created_by = auth.uid(), 'template version stamps created_by');

  tv := public.create_template_version(
    t_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Hello again {{first_name}}', public.test_doc('template body v2'),
    '[{"key":"first_name","label":"First name","required":true}]'::jsonb);
  perform public.test_assert(tv.version_no = 2, 'second template version gets version_no 2');

  begin
    perform public.create_template_version(gen_random_uuid(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 's', public.test_doc('x'), '[]'::jsonb);
    raise exception 'create_template_version accepted a missing template' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'create_template_version raises P0002 for an unknown template');
  end;

  -- cross-workspace: real template, wrong claimed workspace -> P0002
  begin
    perform public.create_template_version(t_id, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 's', public.test_doc('x'), '[]'::jsonb);
    raise exception 'create_template_version accepted a workspace mismatch' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'create_template_version rejects a claimed workspace that does not match the template (P0002)');
  end;
end $$;

-- 12b. create_template_version rejects app-invalid variable schemas in SQL (22023)
--      mirroring src/lib/templates/template-document.ts::declaredVariables.
do $$
declare
  t_id uuid := (select val from t_ctx where key = 'template_a')::uuid;
  bad jsonb;
begin
  foreach bad in array array[
    '{"not":"array"}'::jsonb,                                              -- not an array
    '["string_entry"]'::jsonb,                                            -- element not an object
    '[{"key":"First","label":"x","required":true}]'::jsonb,              -- key not ^[a-z]...
    '[{"key":"1abc","label":"x","required":true}]'::jsonb,               -- key starts with digit
    '[{"key":"ok","label":"","required":true}]'::jsonb,                  -- empty label
    '[{"key":"ok","label":"x"}]'::jsonb,                                 -- missing required
    '[{"key":"ok","label":"x","required":"yes"}]'::jsonb,               -- required not boolean
    '[{"key":"ok","label":"x","required":true,"extra":1}]'::jsonb,       -- unknown key
    '[{"key":"dup","label":"x","required":true},{"key":"dup","label":"y","required":false}]'::jsonb  -- duplicate keys
  ] loop
    begin
      perform public.create_template_version(t_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 's', public.test_doc('x'), bad);
      raise exception 'create_template_version accepted an invalid schema: %', bad using errcode = 'ASSRT';
    exception when sqlstate '22023' then
      perform public.test_assert(true, 'create_template_version rejects app-invalid variable_schema (22023): ' || left(bad::text, 60));
    end;
  end loop;

  -- overlong label (> 200 chars) is rejected too
  begin
    perform public.create_template_version(t_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 's', public.test_doc('x'),
      jsonb_build_array(jsonb_build_object('key','ok','label', repeat('L',201), 'required', true)));
    raise exception 'create_template_version accepted an overlong label' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'create_template_version rejects a label longer than 200 chars (22023)');
  end;

  -- a valid nested schema with multiple entries is accepted
  declare tv public.draft_template_versions;
  begin
    tv := public.create_template_version(t_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Hi {{a}}', public.test_doc('x'),
      '[{"key":"a","label":"A","required":true},{"key":"b_2","label":"B two","required":false}]'::jsonb);
    perform public.test_assert(tv.version_no = 3, 'a valid multi-entry variable_schema is accepted (version 3)');
  end;
end $$;

-- 13. set_default_signature: single default enforced atomically + by index
do $$
declare
  s1 uuid; s2 uuid;
begin
  insert into public.signatures (workspace_id, owner_user_id, name, body_json)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', auth.uid(), 'Formal', public.test_doc('-- Alice'))
  returning id into s1;
  insert into public.signatures (workspace_id, owner_user_id, name, body_json)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', auth.uid(), 'Casual', public.test_doc('cheers, alice'))
  returning id into s2;

  perform public.set_default_signature(s1);
  perform public.test_assert(
    (select is_default from public.signatures where id = s1) = true,
    'set_default_signature marks the signature default');

  perform public.set_default_signature(s2);
  perform public.test_assert(
    (select is_default from public.signatures where id = s2) = true
    and (select is_default from public.signatures where id = s1) = false,
    'set_default_signature atomically moves the default');

  begin
    insert into public.signatures (workspace_id, owner_user_id, name, body_json, is_default)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', auth.uid(), 'Sneaky', public.test_doc('x'), true);
    raise exception 'second default signature was accepted' using errcode = 'ASSRT';
  exception when unique_violation then
    perform public.test_assert(true, 'partial unique index blocks a second default signature');
  end;

  begin
    perform public.set_default_signature(gen_random_uuid());
    raise exception 'set_default_signature accepted an unknown id' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'set_default_signature raises P0002 for an unknown signature');
  end;
end $$;

-- 14. create_attachment_intent: happy path + safe filename derivation
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_a')::uuid;
  a public.draft_attachments;
begin
  a := public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Quarterly Report.PDF', 'application/pdf', 123456);
  perform public.test_assert(a.status = 'pending', 'attachment intent starts as pending');
  perform public.test_assert(a.created_by = auth.uid(), 'attachment intent stamps created_by = auth.uid()');
  perform public.test_assert(a.safe_filename = 'quarterly-report.pdf',
    'safe filename is lowercased and dash-joined, extension preserved');
  perform public.test_assert(
    a.storage_path = a.workspace_id::text || '/' || a.draft_id::text || '/' || a.id::text || '/' || a.safe_filename,
    'storage_path follows the deterministic workspace/draft/attachment/name formula');
  perform public.test_assert(a.storage_bucket = 'draft-attachments', 'attachment uses the draft-attachments bucket');
  insert into t_ctx values ('att_1', a.id::text), ('att_1_path', a.storage_path);

  a := public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '???.???', 'text/plain', 10);
  perform public.test_assert(a.safe_filename = 'attachment',
    'unsalvageable filename falls back to ''attachment''');

  a := public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('a', 240) || '.pdf', 'application/pdf', 10);
  perform public.test_assert(
    char_length(a.safe_filename) = 200 and a.safe_filename like '%.pdf',
    'overlong filename truncated to 200 chars preserving the extension');
end $$;

-- 15. create_attachment_intent: MIME / size / filename validation
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_b')::uuid;
  a public.draft_attachments;
begin
  begin
    perform public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'evil.zip', 'application/zip', 100);
    raise exception 'forbidden MIME type was accepted' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'MIME type outside the allowlist is rejected (22023)');
  end;

  begin
    perform public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'zero.txt', 'text/plain', 0);
    raise exception 'zero-byte size was accepted' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'size_bytes = 0 is rejected (22023)');
  end;

  begin
    perform public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'huge.pdf', 'application/pdf', 10485761);
    raise exception 'oversized file was accepted' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'size_bytes above 10 MiB is rejected (22023)');
  end;

  a := public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'exactly-10-mib.pdf', 'application/pdf', 10485760);
  perform public.test_assert(a.size_bytes = 10485760, 'exactly 10 MiB is accepted');

  begin
    perform public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('n', 256), 'text/plain', 10);
    raise exception 'overlong original filename was accepted' using errcode = 'ASSRT';
  exception when sqlstate '22023' then
    perform public.test_assert(true, 'original filename longer than 255 chars is rejected (22023)');
  end;
end $$;

-- 16. attachment count limit (10 per draft) — serialized under the draft lock
do $$
declare
  d public.drafts;
  i int;
begin
  d := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'count-limit draft', public.test_doc('x'));
  for i in 1..10 loop
    perform public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'file-' || i || '.txt', 'text/plain', 100);
  end loop;
  begin
    perform public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'file-11.txt', 'text/plain', 100);
    raise exception 'eleventh attachment was accepted' using errcode = 'ASSRT';
  exception when sqlstate '54000' then
    perform public.test_assert(true, 'eleventh concurrent attachment intent on a draft is rejected (54000)');
  end;
end $$;

-- 17. attachment total-bytes limit (25 MiB per draft, boundary inclusive)
do $$
declare
  d public.drafts;
begin
  d := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'total-limit draft', public.test_doc('x'));
  perform public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p1.pdf', 'application/pdf', 10485760);
  perform public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p2.pdf', 'application/pdf', 10485760);
  perform public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'p3.pdf', 'application/pdf', 5242880);
  perform public.test_assert(
    (select sum(size_bytes) from public.draft_attachments where draft_id = d.id) = 26214400,
    'total of exactly 25 MiB per draft is accepted');
  begin
    perform public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'straw.txt', 'text/plain', 1);
    raise exception 'byte over the 25 MiB total was accepted' using errcode = 'ASSRT';
  exception when sqlstate '54000' then
    perform public.test_assert(true, 'exceeding 25 MiB total per draft is rejected (54000)');
  end;
end $$;

-- 18. integrity trigger still guards status=ready on privileged UPDATE paths.
--     (Direct authenticated UPDATEs are denied at the privilege level; see the
--      direct-write regression suite. Here we drive the UPDATE as the table
--      owner to prove the BEFORE UPDATE trigger remains a second line of
--      defence for service_role / definer writes.)
reset role;
do $$
declare
  v_att uuid := (select val from t_ctx where key = 'att_1')::uuid;
begin
  begin
    update public.draft_attachments set status = 'ready' where id = v_att;
    raise exception 'unverified attachment became ready' using errcode = 'ASSRT';
  exception when check_violation then
    perform public.test_assert(true, 'UPDATE to ready without verified_at raises (integrity trigger)');
  end;

  begin
    update public.draft_attachments set status = 'ready', verified_at = now() where id = v_att;
    raise exception 'attachment became ready without a storage object' using errcode = 'ASSRT';
  exception when check_violation then
    perform public.test_assert(true, 'ready requires an existing storage object even with verified_at set');
  end;
end $$;
set local role authenticated;

-- 19. finalize_attachment fails while the object is missing
do $$
declare
  v_att uuid := (select val from t_ctx where key = 'att_1')::uuid;
begin
  begin
    perform public.finalize_attachment(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'finalize succeeded without a storage object' using errcode = 'ASSRT';
  exception when sqlstate '55000' then
    perform public.test_assert(true, 'finalize_attachment raises 55000 while the object is missing');
  end;
  perform public.test_assert(
    (select status from public.draft_attachments where id = v_att) = 'pending',
    'attachment still pending after the failed finalize rolled back');
end $$;

-- ===== superuser: emulate the Storage service persisting the upload =====
reset role;
insert into storage.objects (bucket_id, name, metadata)
values (
  'draft-attachments',
  (select val from t_ctx where key = 'att_1_path'),
  jsonb_build_object('size', 123456, 'mimetype', 'application/pdf')
);
set local role authenticated;

-- 20. finalize_attachment succeeds once the object exists with matching size
do $$
declare
  v_att uuid := (select val from t_ctx where key = 'att_1')::uuid;
  a public.draft_attachments;
begin
  a := public.finalize_attachment(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('ab', 32));
  perform public.test_assert(a.status = 'ready', 'finalize_attachment promotes the attachment to ready');
  perform public.test_assert(a.verified_at is not null, 'finalize_attachment stamps verified_at');
  perform public.test_assert(a.sha256 = repeat('ab', 32), 'finalize_attachment records the provided sha256');
end $$;

-- 21. finalize_attachment rejects a size mismatch (55000)
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_b')::uuid;
  a public.draft_attachments;
begin
  a := public.create_attachment_intent(v_draft, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'mismatch.txt', 'text/plain', 500);
  insert into t_ctx values ('att_2', a.id::text), ('att_2_path', a.storage_path);
end $$;

reset role;
insert into storage.objects (bucket_id, name, metadata)
values (
  'draft-attachments',
  (select val from t_ctx where key = 'att_2_path'),
  jsonb_build_object('size', 999)
);
set local role authenticated;

do $$
declare
  v_att uuid := (select val from t_ctx where key = 'att_2')::uuid;
begin
  begin
    perform public.finalize_attachment(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'finalize accepted a size mismatch' using errcode = 'ASSRT';
  exception when sqlstate '55000' then
    perform public.test_assert(true, 'finalize_attachment raises 55000 on object size mismatch');
  end;
end $$;

-- 22. mark_attachment_deleted refuses while the object exists, then succeeds
do $$
declare
  v_att uuid := (select val from t_ctx where key = 'att_1')::uuid;
begin
  begin
    perform public.mark_attachment_deleted(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'mark_attachment_deleted accepted a live object' using errcode = 'ASSRT';
  exception when sqlstate '55000' then
    perform public.test_assert(true, 'mark_attachment_deleted refuses while the storage object exists (55000)');
  end;
end $$;

reset role;
delete from storage.objects
where bucket_id = 'draft-attachments'
  and name = (select val from t_ctx where key = 'att_1_path');
set local role authenticated;

do $$
declare
  v_att uuid := (select val from t_ctx where key = 'att_1')::uuid;
  a public.draft_attachments;
begin
  perform public.mark_attachment_deleted(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  select * into a from public.draft_attachments where id = v_att;
  perform public.test_assert(a.status = 'deleted' and a.deleted_at is not null,
    'mark_attachment_deleted tombstones the row once the object is gone');

  perform public.mark_attachment_deleted(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); -- idempotent
  perform public.test_assert(true, 'mark_attachment_deleted is idempotent for already-deleted rows');

  begin
    perform public.finalize_attachment(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'finalize accepted a deleted attachment' using errcode = 'ASSRT';
  exception when sqlstate '55000' then
    perform public.test_assert(true, 'finalize_attachment refuses status deleted (55000)');
  end;
end $$;

-- 23. deleting a draft cascades through append-only children.
--     drafts is SELECT-only for authenticated, so deletion is a privileged
--     (service_role) operation; the FK ON DELETE CASCADE runs with owner rights.
reset role;
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft_b')::uuid;
  n bigint;
begin
  delete from public.drafts where id = v_draft;
  select count(*) into n from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n = 0, 'draft delete cascades to draft_versions despite append-only grants');
  select count(*) into n from public.draft_attachments where draft_id = v_draft;
  perform public.test_assert(n = 0, 'draft delete cascades to draft_attachments');
end $$;
set local role authenticated;

rollback;

-- Harness hygiene: the helpers are recreated by each test file.
reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
