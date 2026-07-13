-- ============================================================================
-- Phase 3B database tests — confirmed send snapshots (exact draft binding)
--
-- Plain-SQL tests (no pgTAP). Run with: psql -v ON_ERROR_STOP=1 -f <this>
-- against a database with baseline + Phase 2 chain + Phase 3A chain + the
-- 20260716100000 confirmed-snapshots migration applied. Any uncaught exception
-- makes psql exit non-zero (the runner reports FAIL). Each passing assertion
-- emits: NOTICE ok - <message>.
--
-- Proven here:
--   1. CONFIRM-TIME SNAPSHOT — create_send_intent appends an immutable
--      draft_versions snapshot (reason=send_confirmation) of the EXACT
--      confirmed content and binds the intent to it (draft_version_id,
--      proof_version=2), atomically.
--   2. ATOMICITY — a revision mismatch raises P0409 and writes NO intent, NO
--      attempt AND NO snapshot; a sender mismatch (22023) and a cross-workspace
--      draft (P0002) equally leave no snapshot behind.
--   3. IDEMPOTENCY — an identical replay returns the SAME intent and creates
--      no second snapshot; a divergent replay raises P0409.
--   4. IMMUTABILITY — later draft edits and later draft_versions inserts leave
--      the referenced snapshot (and the intent's reference to it) unchanged;
--      authenticated cannot UPDATE/INSERT send_intents directly.
--   5. PRIVATE ACCESSORS — the browser roles cannot EXECUTE the transport
--      snapshot functions (42501); transport_worker CAN execute both and gets
--      exactly the referenced snapshot, while holding NO table privilege on
--      draft_versions; a legacy intent (NULL draft_version_id) fails closed
--      with P0002; get_mirror_snapshot is exact-revision with P0002 on a miss.
--
-- Runs inside a single rolled-back transaction; leaves no rows behind.
-- Distinct UUIDs (5555-based) avoid colliding with the other suites' seeds.
-- ============================================================================

create or replace function public.test_assert(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'ASSERT FAILED: %', p_msg using errcode = 'ASSRT';
  end if;
  raise notice 'ok - %', p_msg;
end;
$$;
-- Harness helper only: role-scoped DO blocks (worker/browser) call it.
grant execute on function public.test_assert(boolean, text) to public;

create or replace function public.test_doc(p_text text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('type','doc','content', jsonb_build_array(
    jsonb_build_object('type','paragraph','content', jsonb_build_array(
      jsonb_build_object('type','text','text',p_text)))));
$$;
grant execute on function public.test_doc(text) to public;

begin;
create temporary table t_ctx (key text primary key, val text) on commit drop;
grant all on table t_ctx to public;

-- ---------------------------------------------------------------------------
-- Fixture (superuser): Sam = member of WS1, Tess = member of WS2; one enabled
-- mailbox per workspace.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('55551111-1111-1111-1111-111111111111', 'sam@example.com', '{"full_name":"Sam"}'),
  ('55553333-3333-3333-3333-333333333333', 'tess@example.com', '{"full_name":"Tess"}');
insert into public.workspaces (id, name) values
  ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Snapshot Workspace One'),
  ('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Snapshot Workspace Two');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55551111-1111-1111-1111-111111111111', 'owner'),
  ('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '55553333-3333-3333-3333-333333333333', 'owner');
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('5555cccc-cccc-cccc-cccc-ccccccccccc1', '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'ops@w5.example.com', true, '55551111-1111-1111-1111-111111111111'),
  ('5555cccc-cccc-cccc-cccc-ccccccccccc2', '5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'ops@w5b.example.com', true, '55553333-3333-3333-3333-333333333333');

-- A draft in WS2 (as Tess) — used only for the cross-workspace denial below.
select set_config('request.jwt.claims',
  '{"sub":"55553333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
do $$
declare d public.drafts;
begin
  d := public.create_draft('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'foreign draft', public.test_doc('foreign'));
  insert into t_ctx values ('foreign_draft', d.id::text);
end $$;
reset role;

-- A draft in WS1 (as Sam), then an autosave edit so the CURRENT content
-- (revision 2) has NO existing draft_versions row: the confirm below must
-- CREATE the snapshot rather than reuse one. (autosave within 10 minutes of the
-- 'initial' version bumps the revision without appending a checkpoint.)
select set_config('request.jwt.claims',
  '{"sub":"55551111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  d public.drafts;
  s jsonb;
begin
  d := public.create_draft('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'v1 subject', public.test_doc('v1 body'));
  s := public.save_draft(d.id, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', d.revision,
                         'confirmed subject', public.test_doc('confirmed body'), 'autosave');
  perform public.test_assert((s ->> 'revision')::bigint = 2 and (s ->> 'version_created')::boolean = false,
    'fixture: autosave edit bumped the draft to revision 2 without a checkpoint version');
  insert into t_ctx values ('draft', d.id::text), ('draft_rev', s ->> 'revision');
end $$;

-- =====================================================================
-- 1. CONFIRM-TIME SNAPSHOT (member Sam)
-- =====================================================================
do $$
declare
  i public.send_intents;
  v public.draft_versions;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
begin
  i := public.create_send_intent(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'confirmed subject', null, null, '[]'::jsonb,
    null, null, 1, 'snap-idem-1');
  perform public.test_assert(i.draft_version_id is not null,
    'confirmation: the intent is bound to a snapshot (draft_version_id set)');
  perform public.test_assert(i.proof_version = 2,
    'confirmation: the intent carries proof_version = 2');
  select * into v from public.draft_versions where id = i.draft_version_id;
  perform public.test_assert(v.reason = 'send_confirmation',
    'confirmation: the snapshot was appended with reason send_confirmation');
  perform public.test_assert(v.draft_id = v_draft and v.workspace_id = '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'confirmation: the snapshot belongs to the confirmed draft and workspace');
  perform public.test_assert(v.source_revision = v_rev,
    'confirmation: the snapshot records the exact confirmed revision');
  perform public.test_assert(v.subject = 'confirmed subject' and v.body_json = public.test_doc('confirmed body'),
    'confirmation: the snapshot captures the exact confirmed subject and body');
  insert into t_ctx values ('intent', i.id::text), ('snapshot', i.draft_version_id::text);
end $$;

-- =====================================================================
-- 2. ATOMICITY — each rejected confirm writes NO intent, NO attempt, NO snapshot
-- =====================================================================

-- 2a. Exact-revision gate: a stale revision raises P0409 (save_draft convention).
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  n_i_before int; n_v_before int; n_a_before int;
  n_i_after int;  n_v_after int;  n_a_after int;
  got text := null;
begin
  select count(*) into n_i_before from public.send_intents;
  select count(*) into n_v_before from public.draft_versions where draft_id = v_draft;
  select count(*) into n_a_before from public.send_attempts;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, 1,                                   -- stale: the draft is at revision 2
      'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb,
      null, null, 1, 'snap-stale-1');
    got := 'no-error';
  exception
    when sqlstate 'P0409' then got := 'P0409';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('atomicity: a stale draft revision raises P0409 (got %s)', got));
  select count(*) into n_i_after from public.send_intents;
  select count(*) into n_v_after from public.draft_versions where draft_id = v_draft;
  select count(*) into n_a_after from public.send_attempts;
  perform public.test_assert(n_i_after = n_i_before, 'atomicity: no send_intent row written on revision mismatch');
  perform public.test_assert(n_a_after = n_a_before, 'atomicity: no send_attempt row written on revision mismatch');
  perform public.test_assert(n_v_after = n_v_before, 'atomicity: no snapshot row written on revision mismatch');
end $$;

-- 2b. Sender mismatch keeps the existing 22023 and leaves no snapshot behind.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  n_v_before int; n_v_after int;
  got text := null;
begin
  select count(*) into n_v_before from public.draft_versions where draft_id = v_draft;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'evil@attacker.example',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb,
      null, null, 1, 'snap-evil-1');
    got := 'no-error';
  exception
    when sqlstate '22023' then got := '22023';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '22023',
    format('atomicity: sender mismatch still raises 22023 (got %s)', got));
  select count(*) into n_v_after from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n_v_after = n_v_before, 'atomicity: no snapshot row written on sender mismatch');
end $$;

-- 2c. A cross-workspace draft raises the uniform P0002 and leaves no snapshot.
do $$
declare
  v_foreign uuid := (select val from t_ctx where key = 'foreign_draft')::uuid;
  n_v_before int; n_v_after int;
  got text := null;
begin
  select count(*) into n_v_before from public.draft_versions where draft_id = v_foreign;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_foreign, 1,                                 -- WS2's draft under WS1's claim
      'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb,
      null, null, 1, 'snap-cross-1');
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('atomicity: a cross-workspace draft raises the uniform P0002 (got %s)', got));
  select count(*) into n_v_after from public.draft_versions where draft_id = v_foreign;
  perform public.test_assert(n_v_after = n_v_before, 'atomicity: no snapshot row written for the foreign draft');
end $$;

-- =====================================================================
-- 3. IDEMPOTENCY — replay semantics around the snapshot
-- =====================================================================

-- 3a. An identical replay returns the SAME intent and creates no second snapshot.
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  n int;
begin
  i := public.create_send_intent(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'confirmed subject', null, null, '[]'::jsonb,
    null, null, 1, 'snap-idem-1');
  perform public.test_assert(i.id = v_intent,
    'idempotency: an identical replay returns the SAME intent');
  perform public.test_assert(i.draft_version_id = v_snapshot,
    'idempotency: the replayed intent still references the original snapshot');
  select count(*) into n from public.draft_versions
    where draft_id = v_draft and reason = 'send_confirmation';
  perform public.test_assert(n = 1,
    'idempotency: an identical replay creates no second send_confirmation snapshot');
end $$;

-- 3b. A divergent replay under the same key raises P0409.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  got text := null;
begin
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["someone-else@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb,
      null, null, 1, 'snap-idem-1');
    got := 'no-error';
  exception
    when sqlstate 'P0409' then got := 'P0409';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('idempotency: a divergent replay under the same key raises P0409 (got %s)', got));
end $$;

-- =====================================================================
-- 4. IMMUTABILITY — the snapshot outlives later draft mutations
-- =====================================================================

-- 4a. A later draft edit (via the save RPC) leaves the snapshot unchanged.
do $$
declare
  v public.draft_versions;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  s jsonb;
begin
  s := public.save_draft(v_draft, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_rev,
                         'edited after confirm', public.test_doc('edited body'), 'autosave');
  perform public.test_assert((s ->> 'revision')::bigint = v_rev + 1,
    'immutability: the draft mutated on after-confirm edit (revision advanced)');
  select * into v from public.draft_versions where id = v_snapshot;
  perform public.test_assert(
    v.subject = 'confirmed subject' and v.body_json = public.test_doc('confirmed body'),
    'immutability: a later draft edit leaves the confirmed snapshot content unchanged');
  insert into t_ctx values ('draft_rev3', s ->> 'revision');
end $$;

-- 4b. A later draft_versions insert does not change the intent's reference.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev3 bigint := (select val from t_ctx where key = 'draft_rev3')::bigint;
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  c jsonb;
begin
  c := public.checkpoint_draft(v_draft, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_rev3, 'manual_checkpoint');
  perform public.test_assert((c ->> 'version_created')::boolean,
    'immutability: a later checkpoint appended a NEW draft_versions row');
  perform public.test_assert(
    (select draft_version_id from public.send_intents where id = v_intent) = v_snapshot,
    'immutability: the later version insert did not change the intent''s referenced snapshot id');
end $$;

-- 4c. authenticated cannot UPDATE send_intents.draft_version_id and cannot
--     INSERT into send_intents directly (SELECT-only grant; 42501).
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  perform public.test_assert(
    not has_table_privilege('authenticated', 'public.send_intents'::regclass, 'UPDATE'),
    'immutability: authenticated holds NO UPDATE privilege on public.send_intents');
  begin
    update public.send_intents set draft_version_id = null where id = v_intent;
    raise exception 'authenticated updated send_intents.draft_version_id' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'immutability: authenticated cannot UPDATE send_intents.draft_version_id (42501)');
  end;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       (select val from t_ctx where key = 'draft')::uuid, 1, 'ops@w5.example.com',
       '{"to":["x@y.com"]}'::jsonb, '<forged@w5.example.com>', 'snap-forged-1',
       auth.uid(), repeat('0', 64));
    raise exception 'authenticated inserted into send_intents' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'immutability: authenticated cannot INSERT into send_intents directly (42501)');
  end;
end $$;

-- 4d. authenticated cannot EXECUTE either transport snapshot function (42501).
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  begin
    perform * from transport.get_send_snapshot(v_intent);
    raise exception 'authenticated executed get_send_snapshot' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'private accessors: authenticated cannot EXECUTE transport.get_send_snapshot (42501)');
  end;
  begin
    perform * from transport.get_mirror_snapshot(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      (select val from t_ctx where key = 'draft')::uuid, 2);
    raise exception 'authenticated executed get_mirror_snapshot' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'private accessors: authenticated cannot EXECUTE transport.get_mirror_snapshot (42501)');
  end;
end $$;
reset role;

-- 4e. anon cannot EXECUTE either transport snapshot function (42501).
set local role anon;
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  begin
    perform * from transport.get_send_snapshot(v_intent);
    raise exception 'anon executed get_send_snapshot' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'private accessors: anon cannot EXECUTE transport.get_send_snapshot (42501)');
  end;
  begin
    perform * from transport.get_mirror_snapshot(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      (select val from t_ctx where key = 'draft')::uuid, 2);
    raise exception 'anon executed get_mirror_snapshot' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'private accessors: anon cannot EXECUTE transport.get_mirror_snapshot (42501)');
  end;
end $$;
reset role;

-- 4f. Catalog matrix: EXECUTE is held by exactly transport_worker + service_role.
do $$
declare r record;
begin
  for r in
    select fn from (values
      ('transport.get_send_snapshot(uuid)'),
      ('transport.get_mirror_snapshot(uuid, uuid, bigint)')
    ) t(fn)
  loop
    perform public.test_assert(
      has_function_privilege('transport_worker', r.fn, 'EXECUTE'),
      format('catalog: transport_worker may EXECUTE %s', r.fn));
    perform public.test_assert(
      has_function_privilege('service_role', r.fn, 'EXECUTE'),
      format('catalog: service_role may EXECUTE %s', r.fn));
    perform public.test_assert(
      not has_function_privilege('public', r.fn, 'EXECUTE')
        and not has_function_privilege('anon', r.fn, 'EXECUTE')
        and not has_function_privilege('authenticated', r.fn, 'EXECUTE'),
      format('catalog: public/anon/authenticated may NOT EXECUTE %s', r.fn));
  end loop;
  -- The worker reads confirmed content ONLY through the accessors: it holds no
  -- table privilege of any kind on public.draft_versions.
  perform public.test_assert(
    not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'SELECT')
      and not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'INSERT')
      and not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'UPDATE')
      and not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'DELETE'),
    'catalog: transport_worker holds NO table privilege on public.draft_versions');
end $$;

-- =====================================================================
-- 5. WORKER READ PATH — exact snapshot via the private accessors
-- =====================================================================
set local role transport_worker;

-- 5a. get_send_snapshot returns exactly the referenced snapshot.
do $$
declare
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  r record;
begin
  select * into r from transport.get_send_snapshot(v_intent);
  perform public.test_assert(r.draft_version_id = v_snapshot,
    'worker: get_send_snapshot returns exactly the referenced snapshot id');
  perform public.test_assert(
    r.workspace_id = '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and r.draft_id = v_draft,
    'worker: get_send_snapshot returns the intent''s workspace and draft');
  perform public.test_assert(r.source_revision = 2,
    'worker: get_send_snapshot returns the exact confirmed revision');
  perform public.test_assert(
    r.subject = 'confirmed subject' and r.body_json = public.test_doc('confirmed body'),
    'worker: get_send_snapshot returns the exact confirmed subject and body');
end $$;

-- 5b. The worker cannot read draft_versions directly — the accessor is its ONLY
--     path to confirmed content (42501).
do $$
begin
  begin
    perform 1 from public.draft_versions limit 1;
    raise exception 'worker SELECTed draft_versions directly' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'worker: cannot SELECT public.draft_versions directly (42501)');
  end;
end $$;

-- 5c. get_mirror_snapshot: exact-revision hit returns the same snapshot; a
--     missing revision and a wrong workspace both raise P0002.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  r record;
  got text;
begin
  select * into r from transport.get_mirror_snapshot(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft, 2);
  perform public.test_assert(r.draft_version_id = v_snapshot,
    'worker: get_mirror_snapshot(ws, draft, 2) returns the confirmed snapshot (newest for that exact revision)');
  perform public.test_assert(
    r.subject = 'confirmed subject' and r.body_json = public.test_doc('confirmed body'),
    'worker: get_mirror_snapshot returns the exact revision-2 content, not the later edit');
  got := null;
  begin
    perform * from transport.get_mirror_snapshot(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft, 999);
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('worker: get_mirror_snapshot raises P0002 for a missing revision (got %s)', got));
  got := null;
  begin
    perform * from transport.get_mirror_snapshot(
      '5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_draft, 2);   -- wrong workspace
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('worker: get_mirror_snapshot raises P0002 on a workspace mismatch (got %s)', got));
end $$;

-- 5d. get_send_snapshot on a nonexistent intent raises P0002.
do $$
declare got text := null;
begin
  begin
    perform * from transport.get_send_snapshot('00000000-0000-0000-0000-000000000000');
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('worker: get_send_snapshot raises P0002 for a missing intent (got %s)', got));
end $$;

reset role;

-- =====================================================================
-- 6. LEGACY INTENTS FAIL CLOSED — NULL draft_version_id is non-sendable
-- =====================================================================

-- Superuser writes a legacy-shaped intent (as rows created before this
-- migration would look: proof_version 1, no snapshot binding).
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  insert into public.send_intents
    (id, workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
     message_id, idempotency_key, confirmed_by, confirmation_proof, proof_version)
  values
    ('55559999-9999-9999-9999-999999999999',
     '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
     v_draft, 1, 'ops@w5.example.com', '{"to":["legacy@example.com"]}'::jsonb,
     '<legacy-55559999@w5.example.com>', 'snap-legacy-1',
     '55551111-1111-1111-1111-111111111111', repeat('0', 64), 1);
  perform public.test_assert(
    (select draft_version_id is null and proof_version = 1
     from public.send_intents where id = '55559999-9999-9999-9999-999999999999'),
    'legacy: a pre-migration-shaped intent has NULL draft_version_id and proof_version 1');
end $$;

set local role transport_worker;
do $$
declare got text := null;
begin
  begin
    perform * from transport.get_send_snapshot('55559999-9999-9999-9999-999999999999');
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('legacy: get_send_snapshot fails closed with P0002 for a NULL draft_version_id intent (got %s)', got));
end $$;
reset role;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
