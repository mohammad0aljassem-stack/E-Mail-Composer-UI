-- ============================================================================
-- Phase 3B database tests — private exact MIME artifacts (Phase 4 hardened)
--
-- Plain-SQL tests (no pgTAP). Run with: psql -v ON_ERROR_STOP=1 -f <this>
-- against a database with the full migration chain (through 20260717100000)
-- applied. Any uncaught exception makes psql exit non-zero. Each passing
-- assertion emits: NOTICE ok - <message>.
--
-- Proven here (the corrected Phase 4 contract):
--   1. ATOMIC CREATE-OR-VERIFY — transport.create_or_verify_send_mime_artifact
--      is the worker's ONLY creation path. A FIRST create succeeds only while the
--      attempt is EXACTLY 'claimed'; first-create in every other state
--      (confirmed/queued/smtp_in_progress/smtp_accepted/sent_copy_pending/
--      completed/needs_human_review/cancelled) fails 23514. A second call with an
--      artifact already present is the restart/reconciliation VERIFY path: an
--      EXACT-identity replay succeeds (returns the existing row, no overwrite)
--      REGARDLESS of the attempt state; any divergence (bytes/hash/size/
--      message_id/workspace/intent) or an oversize fails 23514. Two identical
--      sequential calls return the same id (the attempt-row FOR UPDATE lock +
--      unique(send_attempt_id) make concurrent identical creation safe).
--   2. LEAST PRIVILEGE — the worker holds NO INSERT (direct INSERT => 42501) and
--      NO DELETE (=> 42501); it creates exclusively through the DEFINER function.
--      anon/authenticated cannot SELECT/INSERT/UPDATE/DELETE the table and cannot
--      EXECUTE the function (42501). The BEFORE INSERT trigger's state gate +
--      chain checks fire even for a DIRECT privileged (superuser) INSERT.
--   3. IMMUTABILITY + RETENTION — any UPDATE other than the single clearing
--      transition is 23514; clearing is refused (23514) while the attempt is
--      smtp_in_progress / smtp_accepted / sent_copy_pending / needs_human_review
--      and succeeds once the attempt is completed / cancelled /
--      failed_before_delivery, preserving mime_sha256/size_bytes/message_id/refs;
--      the worker holds NO DELETE.
--   4. GRAPH DELETION — a full workspace cascade removes the derived artifact
--      (the parent attempt/intent/workspace FKs are ON DELETE CASCADE).
--   5. CONTENT HYGIENE — public.transport_audit has no bytea column and this
--      suite's raw MIME marker never appears in any audit row.
--   7. ARTIFACT-BEFORE-SMTP GUARD — a claimed attempt cannot enter
--      smtp_in_progress (23514, stays claimed) until a fully-valid RETAINED
--      artifact exists; once it does the transition succeeds. The guard does NOT
--      fire on claimed -> failed_before_delivery / cancelled / needs_human_review
--      (all work with no artifact). A hash-mismatched artifact can never exist.
--   8. CLEARED-ROW VERIFY — after retention clearing (raw_mime NULL) the
--      create-or-verify path ALWAYS re-hashes the caller's actual p_raw_mime
--      against the stored durable digest/size: forged bytes carrying the stale
--      declared hash/size, a NULL p_raw_mime, or a wrong-size payload are 23514;
--      the ORIGINAL bytes still verify the cleared row.
--
-- Runs inside a single rolled-back transaction; leaves no rows behind.
-- Distinct UUIDs (7777-based) avoid colliding with the other suites' seeds.
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
-- Fixture (superuser): Uma = owner of WS-A; a single enabled mailbox. Every
-- intent below is created via the real contract-v2 RPC (contract_version=2 and
-- a subject that EXACTLY equals the draft's subject — the Slice-1 authority),
-- each seeding its own 'confirmed' send_attempt. One intent/attempt per test
-- axis so no attempt is reused after it grows an artifact.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('77771111-1111-1111-1111-111111111111', 'uma@example.com', '{"full_name":"Uma"}');
insert into public.workspaces (id, name) values
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Artifact Workspace A');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77771111-1111-1111-1111-111111111111', 'owner');
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('7777cccc-cccc-cccc-cccc-ccccccccccc1', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'ops@w7.example.com', true, '77771111-1111-1111-1111-111111111111');

select set_config('request.jwt.claims',
  '{"sub":"77771111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
-- One draft + one send_intent per axis key. The RPC requires contract_version=2
-- and p_subject == the created draft's subject.
do $$
declare
  rec record;
  d public.drafts;
  i public.send_intents;
  a uuid;
begin
  for rec in select * from (values
    ('a1',      'mime a1'),        -- success + divergence + replay + clearing->completed
    ('conc',    'mime conc'),      -- sequential double-call is safe
    ('nhr',     'mime nhr'),       -- clearing blocked in needs_human_review
    ('clrcanc', 'mime clrcanc'),   -- clearing allowed in cancelled
    ('clrfbd',  'mime clrfbd'),    -- clearing allowed in failed_before_delivery
    ('big',     'mime big'),       -- oversize first-create
    ('states',  'mime states'),    -- first-create fails in 6 non-claimed states
    ('nhr2',    'mime nhr2'),      -- first-create fails in needs_human_review
    ('canc',    'mime canc'),      -- first-create fails in cancelled
    ('dgate',   'mime dgate'),     -- direct privileged INSERT: state-gate + chain
    ('dok',     'mime dok'),       -- direct privileged INSERT: valid + duplicate
    ('gnoart',  'mime gnoart'),    -- C1: claimed->smtp_in_progress blocked w/o artifact, then allowed
    ('gfbd',    'mime gfbd'),      -- C1: claimed->failed_before_delivery works w/o artifact
    ('gcanc',   'mime gcanc'),     -- C1: claimed->cancelled works w/o artifact
    ('gnhr',    'mime gnhr'),      -- C1: claimed->needs_human_review works w/o artifact
    ('gmis',    'mime gmis'),      -- C1: a hash-mismatched artifact can never exist
    ('clrver',  'mime clrver')     -- C2: cleared-row verify re-hashes the caller's bytes
  ) v(k, subj)
  loop
    d := public.create_draft('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', rec.subj,
                             public.test_doc('body ' || rec.k));
    i := public.create_send_intent(
      '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '7777cccc-cccc-cccc-cccc-ccccccccccc1',
      d.id, d.revision, 'ops@w7.example.com',
      '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
      rec.subj, null, null, '[]'::jsonb, null, null, 2, 'mime-idem-' || rec.k);
    select id into a from public.send_attempts where send_intent_id = i.id;
    insert into t_ctx values
      ('intent_'  || rec.k, i.id::text),
      ('attempt_' || rec.k, a::text),
      ('msgid_'   || rec.k, i.message_id);
  end loop;
end $$;
reset role;

-- The exact raw MIME payload used throughout (the marker string below also
-- powers the content-hygiene assertion at the end).
do $$
declare v_raw bytea := convert_to(
  'MIME-Version: 1.0' || chr(13) || chr(10) ||
  'Subject: mime a1' || chr(13) || chr(10) ||
  'X-Test-Marker: PHASE3B-RAW-MIME-MARKER' || chr(13) || chr(10) ||
  chr(13) || chr(10) || 'body a1', 'UTF8');
begin
  insert into t_ctx values
    ('raw_hex', encode(v_raw, 'hex')),
    ('raw_sha', encode(sha256(v_raw), 'hex')),
    ('raw_len', octet_length(v_raw)::text);
end $$;

-- Helper: advance an attempt FORWARD along the real happy path to a target state
-- (reads the current state, so it is safe to call repeatedly / from any earlier
-- point; a no-op if already at/past the target). Branch targets
-- (needs_human_review / failed_before_delivery / cancelled) are reached off
-- 'claimed'. Every step is a legal transition through the SECURITY INVOKER
-- BEFORE UPDATE trigger, driven by whatever role calls this (worker or superuser).
create or replace function pg_temp.drive_to(p_attempt uuid, p_target text)
returns void language plpgsql as $$
declare
  path text[] := array['confirmed','queued','claimed','smtp_in_progress',
                        'smtp_accepted','sent_copy_pending','completed'];
  cur text; cur_idx int; tgt_idx int; i int;
begin
  if p_target in ('needs_human_review','failed_before_delivery','cancelled') then
    perform pg_temp.drive_to(p_attempt, 'claimed');
    update public.send_attempts set state = p_target, version = version + 1 where id = p_attempt;
    return;
  end if;
  select state into cur from public.send_attempts where id = p_attempt;
  cur_idx := array_position(path, cur);
  tgt_idx := array_position(path, p_target);
  if cur_idx is null or tgt_idx is null then
    raise exception 'drive_to: unsupported transition % -> %', cur, p_target;
  end if;
  i := cur_idx;
  while i < tgt_idx loop
    update public.send_attempts set state = path[i + 1], version = version + 1 where id = p_attempt;
    i := i + 1;
  end loop;
end;
$$;
grant execute on function pg_temp.drive_to(uuid, text) to public;

-- =====================================================================
-- 1. ATOMIC CREATE-OR-VERIFY (the worker's only creation path)
-- =====================================================================
set local role transport_worker;

-- 1a. First-create in 'claimed' succeeds and stores the exact bytes.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_a1')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_a1')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_a1');
  r transport.send_mime_artifacts;
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  r := transport.create_or_verify_send_mime_artifact(
    v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
  perform public.test_assert(r.id is not null,
    'create/verify: first-create while claimed returns an artifact');
  perform public.test_assert(r.raw_mime = v_raw and r.mime_sha256 = v_sha and r.size_bytes = v_len,
    'create/verify: the stored artifact carries the exact bytes, sha256 and size');
  perform public.test_assert(r.cleared_at is null,
    'create/verify: a fresh artifact is not cleared');
  insert into t_ctx values ('artifact_a1', r.id::text);
end $$;

-- 1b. Divergent args on the VERIFY path each fail 23514 (existing a1 artifact).
--     Every non-target field matches the stored row so exactly one axis diverges.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_a1')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_a1')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_a1');
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  got text;
begin
  -- divergent bytes (same declared hash/size/msgid, different raw)
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, v_i, v_ws, v_msg, v_sha, v_len, convert_to('different bytes entirely', 'UTF8'));
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: divergent raw bytes are rejected 23514 (got %s)', got));

  -- divergent hash
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, v_i, v_ws, v_msg, repeat('0',64), v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: divergent mime_sha256 is rejected 23514 (got %s)', got));

  -- divergent size
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, v_i, v_ws, v_msg, v_sha, v_len + 1, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: divergent size_bytes is rejected 23514 (got %s)', got));

  -- divergent message_id
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, v_i, v_ws, '<forged@w7.example.com>', v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: divergent message_id is rejected 23514 (got %s)', got));

  -- divergent workspace
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, v_i, '7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: divergent workspace_id is rejected 23514 (got %s)', got));

  -- divergent intent
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, '7777dddd-dddd-dddd-dddd-dddddddddddd', v_ws, v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: divergent send_intent_id is rejected 23514 (got %s)', got));
end $$;

-- 1c. Identical replay in 'claimed' returns the SAME row and never overwrites.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_a1')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_a1')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_a1');
  v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
  r transport.send_mime_artifacts;
begin
  r := transport.create_or_verify_send_mime_artifact(
    v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
  perform public.test_assert(r.id = v_art,
    'create/verify: an identical replay while claimed returns the existing artifact');
  perform public.test_assert(r.raw_mime = v_raw and r.cleared_at is null,
    'create/verify: replay never overwrites — bytes still present, not cleared');
end $$;

-- 1d. Two identical SEQUENTIAL calls on a fresh claimed attempt return one id
--     (the FOR UPDATE lock + unique(send_attempt_id) make concurrent create safe).
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_conc')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_conc')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_conc');
  r1 transport.send_mime_artifacts; r2 transport.send_mime_artifacts;
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  r1 := transport.create_or_verify_send_mime_artifact(
    v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
  r2 := transport.create_or_verify_send_mime_artifact(
    v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
  perform public.test_assert(r1.id = r2.id,
    'create/verify: two identical sequential calls return the same id (concurrent-safe)');
end $$;

-- 1e. First-create FAILS (23514) in the pre-'claimed' forward states. NOTE: since
--     the artifact-before-smtp guard (Correction 1) now forbids
--     claimed->smtp_in_progress without a retained artifact, an attempt can no
--     longer legally REACH smtp_in_progress/smtp_accepted/sent_copy_pending/
--     completed with NO artifact — so first-create in those states is unreachable
--     by construction (see the guard tests below). Here the 'states' attempt walks
--     confirmed->queued WITHOUT ever creating, so the function keeps hitting the
--     first-create state gate; the terminal off-'claimed' branches
--     (needs_human_review / cancelled) are covered in 1f.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_states')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_states')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_states');
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  got text;
  st text;
begin
  foreach st in array array['confirmed','queued']
  loop
    -- advance forward to st (both are before 'claimed'; no artifact created)
    perform pg_temp.drive_to(v_a, st);
    got := null;
    begin
      perform transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw);
      got := 'no-error';
    exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
    perform public.test_assert(got='23514',
      format('create/verify: first-create while attempt is %s is rejected 23514 (got %s)', st, got));
  end loop;
end $$;

-- 1f. First-create FAILS in needs_human_review and in cancelled (terminal
--     branches off claimed / confirmed) — separate attempts.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  got text;
begin
  -- needs_human_review
  perform pg_temp.drive_to((select val from t_ctx where key='attempt_nhr2')::uuid, 'needs_human_review');
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      (select val from t_ctx where key='attempt_nhr2')::uuid,
      (select val from t_ctx where key='intent_nhr2')::uuid,
      v_ws, (select val from t_ctx where key='msgid_nhr2'), v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: first-create while needs_human_review is rejected 23514 (got %s)', got));

  -- cancelled
  perform pg_temp.drive_to((select val from t_ctx where key='attempt_canc')::uuid, 'cancelled');
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      (select val from t_ctx where key='attempt_canc')::uuid,
      (select val from t_ctx where key='intent_canc')::uuid,
      v_ws, (select val from t_ctx where key='msgid_canc'), v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: first-create while cancelled is rejected 23514 (got %s)', got));
end $$;

-- 1g. Oversized first-create (26214401 bytes, hash + octet_length exact) fails
--     23514 — the 25 MiB bound is enforced in the function before any insert.
do $$
declare
  v_big bytea := convert_to(repeat('x', 26214401), 'UTF8');
  v_a uuid := (select val from t_ctx where key='attempt_big')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_big')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_big');
  got text := null;
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg,
      encode(sha256(v_big),'hex'), octet_length(v_big)::bigint, v_big);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('create/verify: an oversized (>26214400) payload is rejected 23514 (got %s)', got));
end $$;

reset role;

-- =====================================================================
-- 2. LEAST PRIVILEGE — worker has NO direct INSERT/DELETE; browser has ZERO
--    reach and cannot EXECUTE the creation function.
-- =====================================================================

-- 2a. transport_worker cannot DIRECTLY INSERT (no INSERT grant => 42501): it may
--     only create through the DEFINER function.
set local role transport_worker;
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_dok')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_dok')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_dok');
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
    raise exception 'worker directly INSERTed send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true,
      'least-privilege: transport_worker cannot DIRECTLY INSERT send_mime_artifacts (42501)');
  end;
end $$;

-- 2b. transport_worker cannot DELETE (no DELETE grant => 42501). (a1 exists.)
do $$
declare v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
begin
  begin
    delete from transport.send_mime_artifacts where id = v_art;
    raise exception 'worker DELETEd send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true,
      'least-privilege: transport_worker cannot DELETE send_mime_artifacts (42501)');
  end;
end $$;
reset role;

-- 2c. Browser (authenticated) has ZERO table reach and cannot EXECUTE the
--     creation function (no schema USAGE / no EXECUTE => 42501).
select set_config('request.jwt.claims',
  '{"sub":"77771111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_msg text := (select val from t_ctx where key='msgid_a1');
begin
  begin
    perform 1 from transport.send_mime_artifacts limit 1;
    raise exception 'authenticated SELECTed send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot SELECT send_mime_artifacts (42501)');
  end;
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_art, v_art, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '<x@y>', repeat('0',64), 1, '\x00');
    raise exception 'authenticated INSERTed send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot INSERT send_mime_artifacts (42501)');
  end;
  begin
    update transport.send_mime_artifacts set cleared_at = now() where id = v_art;
    raise exception 'authenticated UPDATEd send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot UPDATE send_mime_artifacts (42501)');
  end;
  begin
    delete from transport.send_mime_artifacts where id = v_art;
    raise exception 'authenticated DELETEd send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot DELETE send_mime_artifacts (42501)');
  end;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      v_art, v_art, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
    raise exception 'authenticated EXECUTEd create_or_verify_send_mime_artifact' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot EXECUTE the creation function (42501)');
  end;
end $$;
reset role;

set local role anon;
do $$
begin
  begin
    perform 1 from transport.send_mime_artifacts limit 1;
    raise exception 'anon SELECTed send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: anon cannot SELECT send_mime_artifacts (42501)');
  end;
  begin
    perform transport.create_or_verify_send_mime_artifact(
      '00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000000000',
      '00000000-0000-0000-0000-000000000000','<x@y>', repeat('0',64), 1, '\x00');
    raise exception 'anon EXECUTEd create_or_verify_send_mime_artifact' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: anon cannot EXECUTE the creation function (42501)');
  end;
end $$;
reset role;

-- 2d. Catalog matrix: worker exactly SELECT+UPDATE (NEVER INSERT/DELETE); browser
--     roles nothing; service_role all.
do $$
declare r record; expected boolean; actual boolean;
begin
  for r in
    select roles.role, privs.priv
    from (values ('anon'),('authenticated'),('service_role'),('transport_worker')) roles(role)
    cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) privs(priv)
  loop
    actual := has_table_privilege(r.role, 'transport.send_mime_artifacts'::regclass, r.priv);
    expected := case
      when r.role = 'service_role' then true
      when r.role in ('anon','authenticated') then false
      else r.priv in ('SELECT','UPDATE')   -- transport_worker: never INSERT/DELETE
    end;
    perform public.test_assert(actual = expected,
      format('artifact privilege: %s %s on send_mime_artifacts = %s', r.role, r.priv, expected));
  end loop;
end $$;

-- 2e. Function EXECUTE matrix: worker + service_role only; browser roles never.
do $$
declare
  v_sig text := 'transport.create_or_verify_send_mime_artifact(uuid, uuid, uuid, text, text, bigint, bytea)';
begin
  perform public.test_assert(has_function_privilege('transport_worker', v_sig, 'EXECUTE'),
    'function privilege: transport_worker may EXECUTE create_or_verify_send_mime_artifact');
  perform public.test_assert(has_function_privilege('service_role', v_sig, 'EXECUTE'),
    'function privilege: service_role may EXECUTE create_or_verify_send_mime_artifact');
  perform public.test_assert(not has_function_privilege('anon', v_sig, 'EXECUTE'),
    'function privilege: anon may NOT EXECUTE create_or_verify_send_mime_artifact');
  perform public.test_assert(not has_function_privilege('authenticated', v_sig, 'EXECUTE'),
    'function privilege: authenticated may NOT EXECUTE create_or_verify_send_mime_artifact');
  perform public.test_assert(not has_function_privilege('public', v_sig, 'EXECUTE'),
    'function privilege: public may NOT EXECUTE create_or_verify_send_mime_artifact');
end $$;

-- =====================================================================
-- 3. DIRECT PRIVILEGED INSERT still passes through the BEFORE INSERT trigger
--    (superuser: bypasses grants, NOT triggers/constraints). Proves the state
--    gate + parent-chain checks + one-per-attempt protect even a direct insert.
-- =====================================================================

-- 3a. State gate: a direct privileged INSERT for a non-'claimed' (confirmed)
--     attempt is rejected 23514 by the trigger.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_dgate')::uuid;   -- still 'confirmed'
  v_i uuid := (select val from t_ctx where key='intent_dgate')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_dgate');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('direct insert: the claimed-state gate rejects a confirmed-attempt insert 23514 (got %s)', got));
end $$;

-- 3b. Chain checks (claimed 'dok' attempt): bad hash / wrong workspace / wrong
--     message_id each 23514; then a valid insert succeeds; a duplicate is 23505.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_dok')::uuid;   -- driven to claimed in 2a
  v_i uuid := (select val from t_ctx where key='intent_dok')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_dok');
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  got text; v_id uuid;
begin
  -- bad hash (valid hex, wrong digest)
  got := null;
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, v_ws, v_msg, repeat('0',64), v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('direct insert: a mime_sha256 not matching sha256(raw_mime) is rejected 23514 (got %s)', got));

  -- wrong workspace
  got := null;
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, '7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('direct insert: a workspace mismatch is rejected 23514 (got %s)', got));

  -- wrong message_id
  got := null;
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, v_ws, '<forged@w7.example.com>', v_sha, v_len, v_raw);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('direct insert: a message_id differing from the intent is rejected 23514 (got %s)', got));

  -- valid direct privileged insert succeeds while claimed
  insert into transport.send_mime_artifacts
    (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
  values (v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw)
  returning id into v_id;
  perform public.test_assert(v_id is not null,
    'direct insert: a valid privileged insert while claimed succeeds (trigger allows)');

  -- duplicate for the same attempt is a unique violation (23505)
  got := null;
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception when unique_violation then got := '23505'; when others then got := sqlstate; end;
  perform public.test_assert(got='23505',
    format('direct insert: a duplicate artifact for the same attempt is 23505 (got %s)', got));
end $$;

-- =====================================================================
-- 4. IMMUTABILITY + RETENTION (worker drives the real state machine)
-- =====================================================================
set local role transport_worker;

-- 4a. Any non-clearing UPDATE is rejected 23514 (raw-byte replacement + metadata
--     edit), even with a self-consistent hash/size for the NEW bytes.
do $$
declare
  v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
  v_new bytea := convert_to('tampered replacement bytes', 'UTF8');
  got text := null;
begin
  begin
    update transport.send_mime_artifacts
      set raw_mime = v_new, mime_sha256 = encode(sha256(v_new),'hex'), size_bytes = octet_length(v_new)
      where id = v_art;
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('immutability: replacing the raw bytes via UPDATE is rejected 23514 (got %s)', got));
  got := null;
  begin
    update transport.send_mime_artifacts set message_id = '<other@w7.example.com>' where id = v_art;
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('immutability: editing artifact metadata via UPDATE is rejected 23514 (got %s)', got));
end $$;

-- 4b. Clearing is REFUSED (23514) and identical replay SUCCEEDS at each
--     non-terminal delivery state as a1 advances claimed->smtp_in_progress->
--     smtp_accepted->sent_copy_pending. Bytes stay present the whole way.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_a1')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_a1')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_a1');
  v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  st text; got text; r transport.send_mime_artifacts;
begin
  foreach st in array array['smtp_in_progress','smtp_accepted','sent_copy_pending']
  loop
    perform pg_temp.drive_to(v_a, st);
    -- replay verify succeeds regardless of state
    r := transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw);
    perform public.test_assert(r.id = v_art and r.raw_mime = v_raw,
      format('retention: identical replay while %s returns the same artifact (no overwrite)', st));
    -- clearing is refused
    got := null;
    begin
      update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_art;
      got := 'no-error';
    exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
    perform public.test_assert(got='23514',
      format('retention: clearing while the attempt is %s is rejected 23514 (got %s)', st, got));
  end loop;
end $$;

-- 4c. Clearing is REFUSED (23514) while needs_human_review (separate attempt with
--     its own function-created artifact).
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_nhr')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_nhr')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_nhr');
  v_id uuid; got text := null;
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  v_id := (transport.create_or_verify_send_mime_artifact(
    v_a, v_i, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw)).id;
  update public.send_attempts set state='needs_human_review', version=version+1 where id=v_a;
  begin
    update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_id;
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('retention: clearing while needs_human_review is rejected 23514 (got %s)', got));
end $$;

-- 4d. Clearing SUCCEEDS after 'completed' and PRESERVES the durable proof
--     metadata (sha256/size/message_id and the parent refs).
do $$
declare
  v_a uuid := (select val from t_ctx where key='attempt_a1')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_a1')::uuid;
  v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_msg text := (select val from t_ctx where key='msgid_a1');
  r transport.send_mime_artifacts;
begin
  -- a1 is currently sent_copy_pending; advance to completed.
  update public.send_attempts set state='completed', version=version+1 where id=v_a;
  update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_art;
  select * into r from transport.send_mime_artifacts where id = v_art;
  perform public.test_assert(r.raw_mime is null and r.cleared_at is not null,
    'retention: clearing after completed succeeds (raw gone, cleared_at stamped)');
  perform public.test_assert(
    r.mime_sha256 = v_sha and r.size_bytes = v_len and r.message_id = v_msg
      and r.send_attempt_id = v_a and r.send_intent_id = v_i,
    'retention: clearing preserves mime_sha256/size_bytes/message_id and the parent refs');
end $$;

-- 4e. A cleared artifact stays frozen: re-attaching bytes is 23514.
do $$
declare
  v_art uuid := (select val from t_ctx where key='artifact_a1')::uuid;
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  got text := null;
begin
  begin
    update transport.send_mime_artifacts set raw_mime = v_raw, cleared_at = null where id = v_art;
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('retention: re-attaching bytes to a cleared artifact is rejected 23514 (got %s)', got));
end $$;

-- 4f. Clearing SUCCEEDS in the other two terminal-for-delivery states:
--     cancelled and failed_before_delivery (separate attempts).
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_a uuid; v_i uuid; v_msg text; v_id uuid; r transport.send_mime_artifacts;
begin
  -- cancelled
  v_a := (select val from t_ctx where key='attempt_clrcanc')::uuid;
  v_i := (select val from t_ctx where key='intent_clrcanc')::uuid;
  v_msg := (select val from t_ctx where key='msgid_clrcanc');
  perform pg_temp.drive_to(v_a, 'claimed');
  v_id := (transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw)).id;
  update public.send_attempts set state='cancelled', version=version+1 where id=v_a;
  update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_id;
  select * into r from transport.send_mime_artifacts where id = v_id;
  perform public.test_assert(r.raw_mime is null and r.cleared_at is not null and r.mime_sha256 = v_sha,
    'retention: clearing after cancelled succeeds and preserves the sha256');

  -- failed_before_delivery
  v_a := (select val from t_ctx where key='attempt_clrfbd')::uuid;
  v_i := (select val from t_ctx where key='intent_clrfbd')::uuid;
  v_msg := (select val from t_ctx where key='msgid_clrfbd');
  perform pg_temp.drive_to(v_a, 'claimed');
  v_id := (transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw)).id;
  update public.send_attempts set state='failed_before_delivery', version=version+1 where id=v_a;
  update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_id;
  select * into r from transport.send_mime_artifacts where id = v_id;
  perform public.test_assert(r.raw_mime is null and r.cleared_at is not null and r.size_bytes = v_len,
    'retention: clearing after failed_before_delivery succeeds and preserves the size');
end $$;

reset role;

-- =====================================================================
-- 7. ARTIFACT-BEFORE-SMTP ORDERING GUARD (Correction 1). A claimed attempt may
--    enter smtp_in_progress ONLY once a fully-valid RETAINED MIME artifact
--    exists (closing the gap where an artifact-less attempt could enter
--    smtp_in_progress, after which creation — state='claimed' only — is
--    permanently impossible); the guard must NOT block the other off-claimed
--    transitions.
-- =====================================================================
set local role transport_worker;

-- 7a. No artifact: claimed->smtp_in_progress is refused 23514 and the attempt
--     STAYS 'claimed'. After a valid retained artifact is created the SAME
--     transition succeeds — so the guard's success provably required the
--     hash/size-consistent artifact (its byte re-check).
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_gnoart')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_gnoart')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_gnoart');
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  got text; st text;
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  -- (a) no artifact -> refused; attempt stays claimed
  got := null;
  begin
    update public.send_attempts set state='smtp_in_progress', version=version+1 where id=v_a;
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('guard: claimed->smtp_in_progress with NO artifact is rejected 23514 (got %s)', got));
  select state into st from public.send_attempts where id=v_a;
  perform public.test_assert(st='claimed',
    'guard: the refused attempt stays in claimed (bytes can still be attached)');

  -- (b) create a valid retained artifact, then the SAME transition succeeds
  perform transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw);
  update public.send_attempts set state='smtp_in_progress', version=version+1 where id=v_a;
  select state into st from public.send_attempts where id=v_a;
  perform public.test_assert(st='smtp_in_progress',
    'guard: with a valid retained artifact claimed->smtp_in_progress succeeds');
end $$;

-- 7b. The guard must NOT fire on the other off-'claimed' transitions: each works
--     with NO artifact (failed_before_delivery / cancelled / needs_human_review).
do $$
declare
  st text;
  v_fbd uuid := (select val from t_ctx where key='attempt_gfbd')::uuid;
  v_canc uuid := (select val from t_ctx where key='attempt_gcanc')::uuid;
  v_nhr uuid := (select val from t_ctx where key='attempt_gnhr')::uuid;
begin
  perform pg_temp.drive_to(v_fbd, 'claimed');
  update public.send_attempts set state='failed_before_delivery', version=version+1 where id=v_fbd;
  select state into st from public.send_attempts where id=v_fbd;
  perform public.test_assert(st='failed_before_delivery',
    'guard: claimed->failed_before_delivery works with NO artifact (guard does not fire)');

  perform pg_temp.drive_to(v_canc, 'claimed');
  update public.send_attempts set state='cancelled', version=version+1 where id=v_canc;
  select state into st from public.send_attempts where id=v_canc;
  perform public.test_assert(st='cancelled',
    'guard: claimed->cancelled works with NO artifact (guard does not fire)');

  perform pg_temp.drive_to(v_nhr, 'claimed');
  update public.send_attempts set state='needs_human_review', version=version+1 where id=v_nhr;
  select state into st from public.send_attempts where id=v_nhr;
  perform public.test_assert(st='needs_human_review',
    'guard: claimed->needs_human_review works with NO artifact (guard does not fire)');
end $$;
reset role;

-- 7c. Belt-and-suspenders for the guard's re-hash: an artifact whose stored
--     mime_sha256 disagrees with its raw_mime can NEVER exist — the BEFORE INSERT
--     trigger blocks it (23514) even for a direct privileged insert on a claimed
--     attempt — so the guard only ever inspects hash/size-consistent rows.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_gmis')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_gmis')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_gmis');
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  got text := null;
begin
  perform pg_temp.drive_to(v_a, 'claimed');
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_a, v_i, v_ws, v_msg, repeat('0',64), v_len, v_raw);  -- valid hex, WRONG digest
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('guard: an artifact whose stored mime_sha256 != sha256(raw_mime) cannot exist (23514, got %s)', got));
end $$;

-- =====================================================================
-- 8. CLEARED-ROW VERIFY RE-HASHES THE CALLER'S BYTES (Correction 2). After
--    retention clearing (raw_mime NULL) the verify path must STILL prove the
--    caller holds the exact bytes by re-hashing p_raw_mime against the stored
--    durable digest/size — echoing the old declared hash/size is NOT enough
--    (the defect let a cleared row verify against arbitrary bytes).
-- =====================================================================
set local role transport_worker;
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key='raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key='raw_sha');
  v_len bigint := (select val from t_ctx where key='raw_len')::bigint;
  v_a uuid := (select val from t_ctx where key='attempt_clrver')::uuid;
  v_i uuid := (select val from t_ctx where key='intent_clrver')::uuid;
  v_msg text := (select val from t_ctx where key='msgid_clrver');
  v_ws uuid := '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_id uuid;
  v_b2 bytea := convert_to('tampered post-clear bytes payload', 'UTF8');  -- sha != v_sha
  v_diffsize bytea := convert_to('short', 'UTF8');                        -- octet_length != v_len
  r transport.send_mime_artifacts;
  got text;
begin
  -- set up: create the artifact while claimed, drive to completed, clear bytes.
  perform pg_temp.drive_to(v_a, 'claimed');
  v_id := (transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw)).id;
  perform pg_temp.drive_to(v_a, 'completed');
  update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_id;
  select * into r from transport.send_mime_artifacts where id = v_id;
  perform public.test_assert(r.raw_mime is null and r.cleared_at is not null,
    'cleared-verify: fixture artifact is cleared (raw gone) before the verify checks');

  -- (1) SAME refs + declared H + declared S but DIFFERENT bytes (sha != H):
  --     this WRONGLY succeeded on a cleared row before the fix; now 23514.
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_b2);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('cleared-verify: same declared hash/size but forged bytes is rejected 23514 (got %s)', got));

  -- (2) ORIGINAL bytes (sha=H, size=S) verify the cleared row successfully.
  r := transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_raw);
  perform public.test_assert(r.id = v_id and r.raw_mime is null and r.cleared_at is not null,
    'cleared-verify: the ORIGINAL bytes verify the cleared row (returns it, still cleared)');

  -- (3) p_raw_mime NULL is rejected 23514 (the caller must present the bytes).
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, null);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('cleared-verify: a NULL p_raw_mime is rejected 23514 (got %s)', got));

  -- (4) Bytes of a DIFFERENT size fail the octet_length re-check: 23514.
  got := null;
  begin
    perform transport.create_or_verify_send_mime_artifact(v_a, v_i, v_ws, v_msg, v_sha, v_len, v_diffsize);
    got := 'no-error';
  exception when sqlstate '23514' then got := '23514'; when others then got := sqlstate; end;
  perform public.test_assert(got='23514',
    format('cleared-verify: bytes of a different size are rejected 23514 (got %s)', got));
end $$;
reset role;

-- =====================================================================
-- 5. CONTENT HYGIENE — the audit trail can never carry raw MIME
-- =====================================================================
do $$
declare n int;
begin
  select count(*) into n
  from pg_attribute
  where attrelid = 'public.transport_audit'::regclass
    and attnum > 0 and not attisdropped
    and atttypid = 'bytea'::regtype;
  perform public.test_assert(n = 0,
    'hygiene: public.transport_audit has no bytea column (raw MIME is structurally impossible)');
  select count(*) into n
  from public.transport_audit
  where detail::text like '%PHASE3B-RAW-MIME-MARKER%'
     or coalesce(message_id, '') like '%PHASE3B-RAW-MIME-MARKER%';
  perform public.test_assert(n = 0,
    'hygiene: no transport_audit row contains this suite''s raw MIME marker');
end $$;

-- =====================================================================
-- 6. GRAPH DELETION — a full workspace cascade removes derived artifacts
--    (parent attempt/intent/workspace FKs are ON DELETE CASCADE).
-- =====================================================================
do $$
declare n_before int; n_after int;
begin
  select count(*) into n_before from transport.send_mime_artifacts
    where workspace_id = '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform public.test_assert(n_before > 0,
    format('graph deletion: artifacts exist before the workspace delete (%s)', n_before));
  delete from public.workspaces where id = '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  select count(*) into n_after from transport.send_mime_artifacts
    where workspace_id = '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform public.test_assert(n_after = 0,
    'graph deletion: the full workspace cascade removed every derived artifact (count 0)');
end $$;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
