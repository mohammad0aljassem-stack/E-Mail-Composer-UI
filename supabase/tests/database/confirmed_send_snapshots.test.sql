-- ============================================================================
-- Phase 3B database tests — confirmed send snapshots (exact draft binding)
--
-- Plain-SQL tests (no pgTAP). Run with: psql -v ON_ERROR_STOP=1 -f <this>
-- against a database with baseline + Phase 2 chain + Phase 3A chain + the
-- 20260716100000 confirmed-snapshots migration applied. Any uncaught exception
-- makes psql exit non-zero (the runner reports FAIL). Each passing assertion
-- emits: NOTICE ok - <message>.
--
-- Proven here (three adversarial phases):
--   PHASE 1 — CONTRACT VERSION 2: create_send_intent defaults p_contract_version
--     to 2 and rejects (22023) any other supplied value (1/3/NULL/negative)
--     BEFORE any snapshot/intent/attempt/audit write; the stored value is the
--     server-owned constant 2. A named row-shape CHECK forbids every hybrid
--     (2/1, 1/2, proof2+null, proof1+notnull); only legacy 1/1/NULL and current
--     2/2/NOT-NULL rows exist. Legacy 1/1/NULL rows are non-sendable (P0002).
--   PHASE 2 — LOCKED SUBJECT IS AUTHORITATIVE: the confirmed subject must EXACTLY
--     equal the locked draft subject (no normalization); any byte difference
--     raises P0409 and leaves no snapshot/intent/attempt/audit. The stored
--     subject, the snapshot subject and the confirmation proof are all the locked
--     subject; a later draft edit never mutates the existing intent or snapshot.
--   PHASE 3 — COMPOSITE IDENTITY + HARDENED ACCESSORS: send_intents is bound to
--     its snapshot by a composite identity FK (draft_version_id, workspace_id,
--     draft_id, draft_revision) -> draft_versions (id, workspace_id, draft_id,
--     source_revision), DEFERRABLE INITIALLY DEFERRED, ON DELETE NO ACTION, so an
--     intent can NEVER reference a foreign-workspace/draft/revision snapshot (the
--     FK rejects the insert). transport.get_send_snapshot returns the exact
--     snapshot only for a fully-formed v2 intent and fails closed with a uniform,
--     non-disclosing P0002 otherwise; the browser roles cannot execute it and the
--     worker cannot read draft_versions directly. A referenced snapshot cannot be
--     deleted from under a live intent (NO ACTION), yet a full workspace cascade
--     removes the whole graph (drafts -> draft_versions + send_intents) in one
--     deferred transaction.
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
-- Fixture (superuser): Sam = member of WS1, Tess = member of WS2, Uwe = member
-- of WS3; one enabled mailbox per workspace.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('55551111-1111-1111-1111-111111111111', 'sam@example.com', '{"full_name":"Sam"}'),
  ('55553333-3333-3333-3333-333333333333', 'tess@example.com', '{"full_name":"Tess"}'),
  ('55554444-4444-4444-4444-444444444444', 'uwe@example.com', '{"full_name":"Uwe"}');
insert into public.workspaces (id, name) values
  ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Snapshot Workspace One'),
  ('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Snapshot Workspace Two'),
  ('5555dddd-dddd-dddd-dddd-dddddddddddd', 'Snapshot Workspace Three');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55551111-1111-1111-1111-111111111111', 'owner'),
  ('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '55553333-3333-3333-3333-333333333333', 'owner'),
  ('5555dddd-dddd-dddd-dddd-dddddddddddd', '55554444-4444-4444-4444-444444444444', 'owner');
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('5555cccc-cccc-cccc-cccc-ccccccccccc1', '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'ops@w5.example.com', true, '55551111-1111-1111-1111-111111111111'),
  ('5555cccc-cccc-cccc-cccc-ccccccccccc2', '5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'ops@w5b.example.com', true, '55553333-3333-3333-3333-333333333333'),
  ('5555cccc-cccc-cccc-cccc-ccccccccccc3', '5555dddd-dddd-dddd-dddd-dddddddddddd',
   'ops@w5c.example.com', true, '55554444-4444-4444-4444-444444444444');

-- A draft in WS2 (as Tess) — used for the cross-workspace denial + the
-- other-workspace composite-FK rejection.
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
-- CREATE the snapshot rather than reuse one. Also a SECOND WS1 draft (for the
-- other-draft composite-FK rejection) and an EMPTY-subject WS1 draft (for the
-- empty==empty subject case).
select set_config('request.jwt.claims',
  '{"sub":"55551111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  d public.drafts;
  d2 public.drafts;
  de public.drafts;
  s jsonb;
begin
  d := public.create_draft('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'v1 subject', public.test_doc('v1 body'));
  s := public.save_draft(d.id, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', d.revision,
                         'confirmed subject', public.test_doc('confirmed body'), 'autosave');
  perform public.test_assert((s ->> 'revision')::bigint = 2 and (s ->> 'version_created')::boolean = false,
    'fixture: autosave edit bumped the draft to revision 2 without a checkpoint version');
  insert into t_ctx values ('draft', d.id::text), ('draft_rev', s ->> 'revision');

  d2 := public.create_draft('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'second draft subject', public.test_doc('second body'));
  insert into t_ctx values ('draft2', d2.id::text);

  de := public.create_draft('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '', public.test_doc('empty subject body'));
  insert into t_ctx values ('draft_empty', de.id::text);
end $$;
reset role;

-- =====================================================================
-- 1. CONFIRM-TIME SNAPSHOT (member Sam) — establishes the primary intent
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"55551111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
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
    null, null, 2, 'snap-idem-1');
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
-- PHASE 1 — TRANSPORT CONTRACT VERSION 2 ENFORCEMENT
-- =====================================================================

-- P1a. The parameter DEFAULTS to 2: omit p_contract_version entirely, and the
--      stored contract_version is 2 (proof 2, snapshot bound).
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
begin
  i := public.create_send_intent(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'confirmed subject', null, null, '[]'::jsonb,
    null, null,
    p_idempotency_key => 'p1-omit-contract');
  perform public.test_assert(i.contract_version = 2,
    'phase1: an OMITTED p_contract_version defaults to the server-owned 2');
  perform public.test_assert(i.proof_version = 2 and i.draft_version_id is not null,
    'phase1: the default-contract intent is a full v2 row (proof 2, snapshot bound)');
end $$;

-- P1b. Explicit exactly-2 succeeds and stores 2/2/not-null.
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
begin
  i := public.create_send_intent(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'confirmed subject', null, null, '[]'::jsonb,
    null, null, 2, 'p1-explicit-2');
  perform public.test_assert(
    i.contract_version = 2 and i.proof_version = 2 and i.draft_version_id is not null,
    'phase1: explicit contract_version=2 succeeds and stores 2/2/NOT-NULL');
end $$;

-- P1c. Every other supplied value is rejected with 22023, and (for the =1 case)
--      leaves NO snapshot / NO intent / NO attempt / NO audit row.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  n_i_before int; n_v_before int; n_a_before int; n_au_before int;
  n_i_after int;  n_v_after int;  n_a_after int;  n_au_after int;
  got text;
begin
  select count(*) into n_i_before from public.send_intents;
  select count(*) into n_v_before from public.draft_versions where draft_id = v_draft;
  select count(*) into n_a_before from public.send_attempts;
  select count(*) into n_au_before from public.transport_audit;

  -- contract_version = 1
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, 1, 'p1-reject-1');
    got := 'no-error';
  exception when sqlstate '22023' then got := '22023'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = '22023',
    format('phase1: contract_version=1 is rejected with 22023 (got %s)', got));

  select count(*) into n_i_after from public.send_intents;
  select count(*) into n_v_after from public.draft_versions where draft_id = v_draft;
  select count(*) into n_a_after from public.send_attempts;
  select count(*) into n_au_after from public.transport_audit;
  perform public.test_assert(n_i_after = n_i_before, 'phase1: a rejected contract version writes NO send_intent');
  perform public.test_assert(n_v_after = n_v_before, 'phase1: a rejected contract version writes NO snapshot');
  perform public.test_assert(n_a_after = n_a_before, 'phase1: a rejected contract version writes NO send_attempt');
  perform public.test_assert(n_au_after = n_au_before, 'phase1: a rejected contract version writes NO audit row');

  -- contract_version = 3
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, 3, 'p1-reject-3');
    got := 'no-error';
  exception when sqlstate '22023' then got := '22023'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = '22023',
    format('phase1: contract_version=3 is rejected with 22023 (got %s)', got));

  -- contract_version = NULL (fail-closed: NULL is not 2)
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, null, 'p1-reject-null');
    got := 'no-error';
  exception when sqlstate '22023' then got := '22023'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = '22023',
    format('phase1: contract_version=NULL is rejected with 22023, fail-closed (got %s)', got));

  -- contract_version = -1 (negative)
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, -1, 'p1-reject-neg');
    got := 'no-error';
  exception when sqlstate '22023' then got := '22023'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = '22023',
    format('phase1: a negative contract_version is rejected with 22023 (got %s)', got));
end $$;
reset role;

-- P1d. A legacy 1/1/NULL fixture (inserted directly as the table owner, exactly
--      as a pre-migration row looks) is a VALID row shape and remains
--      non-sendable: get_send_snapshot fails closed with P0002.
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  insert into public.send_intents
    (id, workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
     message_id, idempotency_key, confirmed_by, confirmation_proof, contract_version, proof_version)
  values
    ('55559999-9999-9999-9999-999999999999',
     '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
     v_draft, 1, 'ops@w5.example.com', '{"to":["legacy@example.com"]}'::jsonb,
     '<legacy-55559999@w5.example.com>', 'snap-legacy-1',
     '55551111-1111-1111-1111-111111111111', repeat('0', 64), 1, 1);
  perform public.test_assert(
    (select draft_version_id is null and proof_version = 1 and contract_version = 1
     from public.send_intents where id = '55559999-9999-9999-9999-999999999999'),
    'phase1: a legacy 1/1/NULL intent is a valid row shape');
end $$;

-- P1e. Every HYBRID shape is rejected by send_intents_proof_contract_shape
--      (check-constraint violation, 23514). Each is an owner-path direct insert.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  got text;
begin
  -- 2/1 hybrid (proof 2, contract 1) — forbidden.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       v_draft, v_rev, 'ops@w5.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<hybrid21@w5.example.com>', 'p1-hybrid-21',
       '55551111-1111-1111-1111-111111111111', repeat('0', 64), v_snapshot, 1, 2);
    got := 'no-error';
  exception when check_violation then got := 'CHECK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'CHECK',
    format('phase1: a 2/1 hybrid (proof2, contract1) is rejected by the shape check (got %s)', got));

  -- 1/2 hybrid (proof 1, contract 2) — forbidden.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       v_draft, 1, 'ops@w5.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<hybrid12@w5.example.com>', 'p1-hybrid-12',
       '55551111-1111-1111-1111-111111111111', repeat('0', 64), null, 2, 1);
    got := 'no-error';
  exception when check_violation then got := 'CHECK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'CHECK',
    format('phase1: a 1/2 hybrid (proof1, contract2) is rejected by the shape check (got %s)', got));

  -- proof 2 + NULL draft_version_id — forbidden.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       v_draft, v_rev, 'ops@w5.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<proof2null@w5.example.com>', 'p1-proof2-null',
       '55551111-1111-1111-1111-111111111111', repeat('0', 64), null, 2, 2);
    got := 'no-error';
  exception when check_violation then got := 'CHECK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'CHECK',
    format('phase1: proof_version 2 with a NULL snapshot is rejected by the shape check (got %s)', got));

  -- proof 1 + non-null draft_version_id — forbidden.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       v_draft, v_rev, 'ops@w5.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<proof1snap@w5.example.com>', 'p1-proof1-snap',
       '55551111-1111-1111-1111-111111111111', repeat('0', 64), v_snapshot, 1, 1);
    got := 'no-error';
  exception when check_violation then got := 'CHECK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'CHECK',
    format('phase1: proof_version 1 with a non-null snapshot is rejected by the shape check (got %s)', got));
end $$;

-- =====================================================================
-- PHASE 2 — LOCKED DRAFT SUBJECT IS AUTHORITATIVE
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"55551111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;

-- P2a. A subject that EXACTLY equals the locked draft subject succeeds, and the
--      stored subject + snapshot subject + recomputed proof are all authoritative.
do $$
declare
  i public.send_intents;
  v public.draft_versions;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  v_recomputed text;
begin
  i := public.create_send_intent(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'confirmed subject', null, null, '[]'::jsonb,
    null, null, 2, 'p2-identical');
  perform public.test_assert(i.subject = 'confirmed subject',
    'phase2: intent.subject equals the locked draft subject');
  select * into v from public.draft_versions where id = i.draft_version_id;
  perform public.test_assert(v.subject = 'confirmed subject',
    'phase2: snapshot.subject equals the locked draft subject');
  -- Recompute the confirmation proof over the canonical (jsonb sorts keys, so the
  -- build order is irrelevant): it must match the stored proof, proving the proof
  -- was computed over the LOCKED subject.
  v_recomputed := encode(sha256(convert_to(jsonb_build_object(
    'workspace_id', i.workspace_id, 'mailbox_id', i.mailbox_id, 'draft_id', i.draft_id,
    'draft_revision', i.draft_revision, 'sender', i.sender, 'recipients', i.recipients,
    'subject', i.subject, 'html_hash', i.html_hash, 'text_hash', i.text_hash,
    'attachment_manifest', i.attachment_manifest, 'template_version_id', i.template_version_id,
    'signature_id', i.signature_id, 'message_id', i.message_id,
    'contract_version', i.contract_version, 'confirmed_by', i.confirmed_by,
    'proof_version', i.proof_version, 'draft_version_id', i.draft_version_id
  )::text, 'UTF8')), 'hex');
  perform public.test_assert(v_recomputed = i.confirmation_proof,
    'phase2: the confirmation proof recomputed over the locked subject matches the stored proof');
end $$;

-- P2b. Every subject that DIFFERS from the locked subject in any byte raises
--      P0409 (no normalization). A different subject also leaves no snapshot/
--      intent/attempt/audit behind.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  n_i_before int; n_v_before int; n_a_before int; n_au_before int;
  n_i_after int;  n_v_after int;  n_a_after int;  n_au_after int;
  got text;
begin
  select count(*) into n_i_before from public.send_intents;
  select count(*) into n_v_before from public.draft_versions where draft_id = v_draft;
  select count(*) into n_a_before from public.send_attempts;
  select count(*) into n_au_before from public.transport_audit;

  -- Wholly different subject.
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'a totally different subject', null, null, '[]'::jsonb, null, null, 2, 'p2-diff');
    got := 'no-error';
  exception when sqlstate 'P0409' then got := 'P0409'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('phase2: a different subject raises P0409 (got %s)', got));

  select count(*) into n_i_after from public.send_intents;
  select count(*) into n_v_after from public.draft_versions where draft_id = v_draft;
  select count(*) into n_a_after from public.send_attempts;
  select count(*) into n_au_after from public.transport_audit;
  perform public.test_assert(n_i_after = n_i_before, 'phase2: a subject mismatch writes NO send_intent');
  perform public.test_assert(n_v_after = n_v_before, 'phase2: a subject mismatch writes NO snapshot');
  perform public.test_assert(n_a_after = n_a_before, 'phase2: a subject mismatch writes NO send_attempt');
  perform public.test_assert(n_au_after = n_au_before, 'phase2: a subject mismatch writes NO audit row');

  -- Case-only difference.
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'Confirmed Subject', null, null, '[]'::jsonb, null, null, 2, 'p2-case');
    got := 'no-error';
  exception when sqlstate 'P0409' then got := 'P0409'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('phase2: a case-only subject difference raises P0409 (no case fold) (got %s)', got));

  -- Trailing-space difference.
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject ', null, null, '[]'::jsonb, null, null, 2, 'p2-trail');
    got := 'no-error';
  exception when sqlstate 'P0409' then got := 'P0409'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('phase2: a trailing-space subject difference raises P0409 (no trim) (got %s)', got));

  -- Leading-space difference.
  got := null;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      ' confirmed subject', null, null, '[]'::jsonb, null, null, 2, 'p2-lead');
    got := 'no-error';
  exception when sqlstate 'P0409' then got := 'P0409'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('phase2: a leading-space subject difference raises P0409 (no trim) (got %s)', got));
end $$;

-- P2c. empty == empty succeeds: a draft with an empty subject confirmed with a
--      NULL/empty p_subject (coalesced to '') matches and stores ''.
do $$
declare
  i public.send_intents;
  v_de uuid := (select val from t_ctx where key = 'draft_empty')::uuid;
begin
  i := public.create_send_intent(
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_de, 1, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    null, null, null, '[]'::jsonb,
    null, null, 2, 'p2-empty');
  perform public.test_assert(i.subject = '' and i.draft_version_id is not null,
    'phase2: empty p_subject against an empty locked subject succeeds and stores ''''');
end $$;

-- P2d. A later draft subject edit leaves the EXISTING intent AND its snapshot
--      unchanged (immutability of the confirmed content).
do $$
declare
  v public.draft_versions;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  s jsonb;
begin
  s := public.save_draft(v_draft, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_rev,
                         'edited after confirm', public.test_doc('edited body'), 'autosave');
  perform public.test_assert((s ->> 'revision')::bigint = v_rev + 1,
    'phase2: the draft mutated on an after-confirm subject edit (revision advanced)');
  perform public.test_assert(
    (select subject from public.send_intents where id = v_intent) = 'confirmed subject',
    'phase2: a later draft subject edit leaves the existing intent.subject unchanged');
  select * into v from public.draft_versions where id = v_snapshot;
  perform public.test_assert(
    v.subject = 'confirmed subject' and v.body_json = public.test_doc('confirmed body'),
    'phase2: a later draft subject edit leaves the confirmed snapshot unchanged');
  insert into t_ctx values ('draft_rev3', s ->> 'revision');
end $$;

-- P2e. A divergent idempotent replay (same key, DIFFERENT subject) raises P0409.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  got text := null;
begin
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'a different replay subject', null, null, '[]'::jsonb, null, null, 2, 'snap-idem-1');
    got := 'no-error';
  exception when sqlstate 'P0409' then got := 'P0409'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('phase2: a divergent replay (same key, different subject) raises P0409 (got %s)', got));
end $$;
reset role;

-- =====================================================================
-- ATOMICITY (retained from the original suite; updated to contract v2) —
-- each rejected confirm writes NO intent, NO attempt, NO snapshot.
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"55551111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;

-- Stale revision -> P0409.
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
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, 1, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, 2, 'snap-stale-1');
    got := 'no-error';
  exception when sqlstate 'P0409' then got := 'P0409'; when others then got := sqlstate;
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

-- Sender mismatch -> 22023, no snapshot.
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
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'evil@attacker.example',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, 2, 'snap-evil-1');
    got := 'no-error';
  exception when sqlstate '22023' then got := '22023'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = '22023',
    format('atomicity: sender mismatch still raises 22023 (got %s)', got));
  select count(*) into n_v_after from public.draft_versions where draft_id = v_draft;
  perform public.test_assert(n_v_after = n_v_before, 'atomicity: no snapshot row written on sender mismatch');
end $$;

-- Cross-workspace draft -> uniform P0002, no snapshot.
do $$
declare
  v_foreign uuid := (select val from t_ctx where key = 'foreign_draft')::uuid;
  n_v_before int; n_v_after int;
  got text := null;
begin
  select count(*) into n_v_before from public.draft_versions where draft_id = v_foreign;
  begin
    perform public.create_send_intent(
      '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
      v_foreign, 1, 'ops@w5.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      'confirmed subject', null, null, '[]'::jsonb, null, null, 2, 'snap-cross-1');
    got := 'no-error';
  exception when sqlstate 'P0002' then got := 'P0002'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('atomicity: a cross-workspace draft raises the uniform P0002 (got %s)', got));
  select count(*) into n_v_after from public.draft_versions where draft_id = v_foreign;
  perform public.test_assert(n_v_after = n_v_before, 'atomicity: no snapshot row written for the foreign draft');
end $$;

-- Idempotency: an identical replay returns the SAME intent, no second snapshot.
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
    '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w5.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'confirmed subject', null, null, '[]'::jsonb, null, null, 2, 'snap-idem-1');
  perform public.test_assert(i.id = v_intent,
    'idempotency: an identical replay returns the SAME intent');
  perform public.test_assert(i.draft_version_id = v_snapshot,
    'idempotency: the replayed intent still references the original snapshot');
  select count(*) into n from public.draft_versions
    where draft_id = v_draft and reason = 'send_confirmation';
  perform public.test_assert(n = 1,
    'idempotency: an identical replay creates no second send_confirmation snapshot');
end $$;

-- Direct-write immutability: authenticated cannot UPDATE/INSERT send_intents.
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

-- authenticated cannot EXECUTE either transport snapshot function (42501).
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

-- anon cannot EXECUTE either transport snapshot function (42501).
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

-- Catalog matrix: EXECUTE is held by exactly transport_worker + service_role.
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
  perform public.test_assert(
    not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'SELECT')
      and not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'INSERT')
      and not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'UPDATE')
      and not has_table_privilege('transport_worker', 'public.draft_versions'::regclass, 'DELETE'),
    'catalog: transport_worker holds NO table privilege on public.draft_versions');
end $$;

-- =====================================================================
-- PHASE 3 — COMPOSITE IDENTITY + HARDENED ACCESSORS
-- =====================================================================

-- P3a. WORKER READ PATH: get_send_snapshot returns exactly the referenced
--      snapshot for a valid v2 intent.
set local role transport_worker;
do $$
declare
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  r record;
begin
  select * into r from transport.get_send_snapshot(v_intent);
  perform public.test_assert(r.draft_version_id = v_snapshot,
    'phase3: get_send_snapshot resolves a valid v2 intent to exactly its snapshot');
  perform public.test_assert(
    r.workspace_id = '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and r.draft_id = v_draft,
    'phase3: get_send_snapshot returns the intent''s workspace and draft');
  perform public.test_assert(r.source_revision = 2,
    'phase3: get_send_snapshot returns the exact confirmed revision');
  perform public.test_assert(
    r.subject = 'confirmed subject' and r.body_json = public.test_doc('confirmed body'),
    'phase3: get_send_snapshot returns the exact confirmed subject and body');
end $$;

-- P3b. The worker cannot read draft_versions directly (42501).
do $$
begin
  begin
    perform 1 from public.draft_versions limit 1;
    raise exception 'worker SELECTed draft_versions directly' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'phase3: transport_worker cannot SELECT public.draft_versions directly (42501)');
  end;
end $$;

-- P3c. A legacy (1/1/NULL) intent and a nonexistent intent both fail closed with
--      the uniform P0002.
do $$
declare got text;
begin
  got := null;
  begin
    perform * from transport.get_send_snapshot('55559999-9999-9999-9999-999999999999');  -- legacy 1/1/null
    got := 'no-error';
  exception when sqlstate 'P0002' then got := 'P0002'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('phase3: a legacy 1/1/NULL intent is non-sendable — get_send_snapshot raises P0002 (got %s)', got));

  got := null;
  begin
    perform * from transport.get_send_snapshot('00000000-0000-0000-0000-000000000000');  -- missing intent
    got := 'no-error';
  exception when sqlstate 'P0002' then got := 'P0002'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('phase3: a missing intent raises the uniform P0002 (got %s)', got));
end $$;

-- P3d. get_mirror_snapshot: exact-revision hit; missing revision + wrong
--      workspace both raise P0002 (workspace is part of the exact-match key).
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
    'phase3: get_mirror_snapshot(ws, draft, 2) returns the confirmed snapshot for that exact revision');
  perform public.test_assert(
    r.subject = 'confirmed subject' and r.body_json = public.test_doc('confirmed body'),
    'phase3: get_mirror_snapshot returns the exact revision-2 content, not a later edit');
  got := null;
  begin
    perform * from transport.get_mirror_snapshot('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft, 999);
    got := 'no-error';
  exception when sqlstate 'P0002' then got := 'P0002'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('phase3: get_mirror_snapshot raises P0002 for a missing revision (got %s)', got));
  got := null;
  begin
    perform * from transport.get_mirror_snapshot('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_draft, 2);
    got := 'no-error';
  exception when sqlstate 'P0002' then got := 'P0002'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('phase3: get_mirror_snapshot raises P0002 on a workspace mismatch (got %s)', got));
end $$;
reset role;

-- P3e. COMPOSITE IDENTITY FK rejects every mismatched (owner-path) intent insert.
--      Because the FK is DEFERRABLE INITIALLY DEFERRED, we force the check with
--      SET CONSTRAINTS ALL IMMEDIATE inside a subtransaction; the exception both
--      surfaces the foreign_key_violation (23503) AND rolls the insert back.
do $$
declare
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;   -- (ws1, draft1, rev2)
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;          -- draft1 (ws1)
  v_draft2 uuid := (select val from t_ctx where key = 'draft2')::uuid;        -- draft2 (ws1)
  v_foreign uuid := (select val from t_ctx where key = 'foreign_draft')::uuid;-- ws2 draft
  got text;
begin
  -- other-REVISION: intent (ws1, draft1, revision 999) pointing at the rev-2 snapshot.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       v_draft, 999, 'ops@w5.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<fk-rev@w5.example.com>', 'p3-fk-rev',
       '55551111-1111-1111-1111-111111111111', repeat('0', 64), v_snapshot, 2, 2);
    set constraints all immediate;
    got := 'no-error';
  exception when foreign_key_violation then got := 'FK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'FK',
    format('phase3: the composite FK rejects an intent whose draft_revision != snapshot.source_revision (got %s)', got));

  -- other-DRAFT: intent claims draft2 but points at draft1''s snapshot.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '5555cccc-cccc-cccc-cccc-ccccccccccc1',
       v_draft2, 2, 'ops@w5.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<fk-draft@w5.example.com>', 'p3-fk-draft',
       '55551111-1111-1111-1111-111111111111', repeat('0', 64), v_snapshot, 2, 2);
    set constraints all immediate;
    got := 'no-error';
  exception when foreign_key_violation then got := 'FK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'FK',
    format('phase3: the composite FK rejects an intent whose draft_id != snapshot.draft_id (got %s)', got));

  -- other-WORKSPACE: intent in ws2 (ws2 mailbox + ws2 draft) points at ws1''s snapshot.
  got := null;
  begin
    insert into public.send_intents
      (workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
       message_id, idempotency_key, confirmed_by, confirmation_proof,
       draft_version_id, contract_version, proof_version)
    values
      ('5555bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '5555cccc-cccc-cccc-cccc-ccccccccccc2',
       v_foreign, 1, 'ops@w5b.example.com', '{"to":["x@y.com"]}'::jsonb,
       '<fk-ws@w5b.example.com>', 'p3-fk-ws',
       '55553333-3333-3333-3333-333333333333', repeat('0', 64), v_snapshot, 2, 2);
    set constraints all immediate;
    got := 'no-error';
  exception when foreign_key_violation then got := 'FK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'FK',
    format('phase3: the composite FK rejects an intent whose workspace_id != snapshot.workspace_id (got %s)', got));

  set constraints all deferred;  -- restore the default mode for the rest of the txn
end $$;

-- P3f. A later draft_versions insert does not change the intent''s resolved
--      result (get_send_snapshot still returns the original snapshot).
select set_config('request.jwt.claims',
  '{"sub":"55551111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev3 bigint := (select val from t_ctx where key = 'draft_rev3')::bigint;
  c jsonb;
begin
  c := public.checkpoint_draft(v_draft, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_rev3, 'manual_checkpoint');
  perform public.test_assert((c ->> 'version_created')::boolean,
    'phase3: a later checkpoint appended a NEW draft_versions row');
end $$;
reset role;

set local role transport_worker;
do $$
declare
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  r record;
begin
  select * into r from transport.get_send_snapshot(v_intent);
  perform public.test_assert(r.draft_version_id = v_snapshot,
    'phase3: a later draft_versions insert does not change get_send_snapshot''s resolved snapshot');
end $$;
reset role;

-- P3g. A referenced snapshot CANNOT be deleted from under a live intent
--      (composite FK, ON DELETE NO ACTION). Deferred, so we force the check.
do $$
declare
  v_snapshot uuid := (select val from t_ctx where key = 'snapshot')::uuid;
  got text := null;
begin
  begin
    delete from public.draft_versions where id = v_snapshot;
    set constraints all immediate;
    got := 'no-error';
  exception when foreign_key_violation then got := 'FK'; when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'FK',
    format('phase3: deleting a referenced snapshot alone is blocked by the composite FK (NO ACTION) (got %s)', got));
end $$;

-- P3h. Deleting the COMPLETE graph via a workspace cascade SUCCEEDS: build a
--      dedicated WS3 with a real v2 intent, then delete the workspace and force
--      the deferred FK to settle. The cascade removes drafts -> draft_versions +
--      send_intents (+ attempts + audit) without the composite FK blocking.
select set_config('request.jwt.claims',
  '{"sub":"55554444-4444-4444-4444-444444444444","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  d public.drafts;
  i public.send_intents;
begin
  d := public.create_draft('5555dddd-dddd-dddd-dddd-dddddddddddd', 'w3 subject', public.test_doc('w3 body'));
  i := public.create_send_intent(
    '5555dddd-dddd-dddd-dddd-dddddddddddd', '5555cccc-cccc-cccc-cccc-ccccccccccc3',
    d.id, d.revision, 'ops@w5c.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'w3 subject', null, null, '[]'::jsonb, null, null, 2, 'p3-cascade');
  perform public.test_assert(i.draft_version_id is not null,
    'phase3: WS3 has a real v2 intent bound to a snapshot before the cascade');
  insert into t_ctx values ('w3_intent', i.id::text);
end $$;
reset role;

do $$
declare n_i int; n_v int; n_d int;
begin
  delete from public.workspaces where id = '5555dddd-dddd-dddd-dddd-dddddddddddd';
  set constraints all immediate;  -- settle the deferred composite FK now
  select count(*) into n_i from public.send_intents where workspace_id = '5555dddd-dddd-dddd-dddd-dddddddddddd';
  select count(*) into n_d from public.drafts where workspace_id = '5555dddd-dddd-dddd-dddd-dddddddddddd';
  select count(*) into n_v from public.draft_versions where workspace_id = '5555dddd-dddd-dddd-dddd-dddddddddddd';
  perform public.test_assert(n_i = 0 and n_d = 0 and n_v = 0,
    'phase3: a full workspace cascade removes drafts + draft_versions + send_intents without the composite FK blocking');
  set constraints all deferred;
end $$;

-- P3i. The composite identity constraints exist (their presence + the double
--      migration apply in the runner prove idempotency of the guarded DO blocks).
do $$
begin
  perform public.test_assert(
    exists (select 1 from pg_constraint
            where conname = 'draft_versions_identity_uq'
              and conrelid = 'public.draft_versions'::regclass and contype = 'u'),
    'phase3: the composite UNIQUE draft_versions_identity_uq exists (idempotent across re-apply)');
  perform public.test_assert(
    exists (select 1 from pg_constraint
            where conname = 'send_intents_draft_version_identity_fk'
              and conrelid = 'public.send_intents'::regclass and contype = 'f' and condeferrable),
    'phase3: the DEFERRABLE composite FK send_intents_draft_version_identity_fk exists (idempotent across re-apply)');
  perform public.test_assert(
    exists (select 1 from pg_constraint
            where conname = 'send_intents_proof_contract_shape'
              and conrelid = 'public.send_intents'::regclass and contype = 'c'),
    'phase3: the row-shape CHECK send_intents_proof_contract_shape exists (idempotent across re-apply)');
  perform public.test_assert(
    not exists (select 1 from pg_constraint
                where conname = 'send_intents_draft_version_fk'
                  and conrelid = 'public.send_intents'::regclass),
    'phase3: the old single-column existence-only FK send_intents_draft_version_fk is gone');
end $$;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
