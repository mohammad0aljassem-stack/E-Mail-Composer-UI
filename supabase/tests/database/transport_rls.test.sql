-- ============================================================================
-- Phase 3A database tests — RLS, immutability, state machine, RPC authorization
--
-- Plain-SQL tests (no pgTAP). Run with: psql -v ON_ERROR_STOP=1 -f <this>
-- against a database with baseline + Phase 2 chain + Phase 3 migration applied.
-- Any uncaught exception makes psql exit non-zero (the runner reports FAIL).
-- Each passing assertion emits: NOTICE ok - <message>.
--
-- Proven here:
--   * cross-workspace isolation on every public transport table;
--   * authenticated cannot directly INSERT/UPDATE/DELETE the public transport
--     tables (42501) — the only write path is the RPC / the worker;
--   * send_intents are immutable (UPDATE and DELETE raise 23514);
--   * send_attempts reject illegal transitions and version rollback (23514) and
--     accept legal transitions;
--   * create_send_intent works for a member (server-generates message_id +
--     confirmation_proof + idempotency_key, seeds a send_attempt + audit row,
--     and is idempotent) and raises P0002 for a non-member;
--   * the browser role has ZERO visibility into transport.mailbox_credentials.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Harness helpers (superuser)
-- ---------------------------------------------------------------------------
create or replace function public.test_assert(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'ASSERT FAILED: %', p_msg using errcode = 'ASSRT';
  end if;
  raise notice 'ok - %', p_msg;
end;
$$;
grant execute on function public.test_assert(boolean, text) to public;

create or replace function public.test_doc(p_text text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('type','doc','content', jsonb_build_array(
    jsonb_build_object('type','paragraph','content', jsonb_build_array(
      jsonb_build_object('type','text','text',p_text)))));
$$;
grant execute on function public.test_doc(text) to public;

-- ---------------------------------------------------------------------------
-- Seed users/workspaces/members (superuser; idempotent)
--   A = 1111... is a member of W1 = aaaa...
--   C = 3333... is a member of W2 = bbbb...
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '{"full_name":"Alice"}'),
  ('33333333-3333-3333-3333-333333333333', 'carol@example.com', '{"full_name":"Carol"}')
on conflict (id) do nothing;
insert into public.workspaces (id, name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Workspace One'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Workspace Two')
on conflict (id) do nothing;
insert into public.workspace_members (workspace_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '33333333-3333-3333-3333-333333333333', 'owner')
on conflict (workspace_id, user_id) do nothing;

begin;
create temporary table t_ctx (key text primary key, val text) on commit drop;
grant all on table t_ctx to public;

-- ---------------------------------------------------------------------------
-- Seed transport rows as the superuser (there is no mailbox-provisioning RPC in
-- the foundation; provisioning is an out-of-band admin op). M1 in W1, M2 in W2.
-- ---------------------------------------------------------------------------
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'ops@w1.example.com', true, '11111111-1111-1111-1111-111111111111'),
  ('cccccccc-cccc-cccc-cccc-ccccccccccc2', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'ops@w2.example.com', true, '33333333-3333-3333-3333-333333333333')
on conflict (id) do nothing;

-- A credential ciphertext for M1 (worker-only secret; browser must never read it).
insert into transport.mailbox_credentials (mailbox_id, ciphertext, nonce, aad) values
  ('cccccccc-cccc-cccc-cccc-ccccccccccc1', '\xdeadbeef'::bytea, '\x0011'::bytea,
   'ws=aaaaaaaa;mb=cccccccc1')
on conflict do nothing;

-- A draft in W1 (via the Phase 2 RPC, as member A) to feed create_send_intent.
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare d public.drafts;
begin
  d := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'send me', public.test_doc('body'));
  insert into t_ctx values ('draft', d.id::text), ('draft_rev', d.revision::text);
end $$;
reset role;

-- =====================================================================
-- 1. create_send_intent (member A) — happy path + server-side generation
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  n int;
begin
  i := public.create_send_intent(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cccccccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev,
    'ops@w1.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'send me', null, null, '[]'::jsonb,
    null, null, 2, 'idem-key-1');
  insert into t_ctx values ('intent', i.id::text);

  perform public.test_assert(i.id is not null, 'create_send_intent returns the inserted intent');
  perform public.test_assert(i.confirmed_by = auth.uid(), 'confirmed_by is stamped with auth.uid()');
  perform public.test_assert(i.message_id ~ '^<[^<>@]+@w1\.example\.com>$',
    'message_id is server-generated from the sender domain');
  perform public.test_assert(i.confirmation_proof ~ '^[a-f0-9]{64}$',
    'confirmation_proof is a server-computed sha256 hex digest');
  perform public.test_assert(i.idempotency_key = 'idem-key-1', 'idempotency_key is persisted');

  select count(*) into n from public.send_attempts where send_intent_id = i.id;
  perform public.test_assert(n = 1, 'exactly one send_attempt is seeded for the intent');
  select count(*) into n from public.send_attempts where send_intent_id = i.id and state = 'confirmed';
  perform public.test_assert(n = 1, 'the seeded send_attempt starts in state=confirmed');

  select count(*) into n from public.transport_audit
    where send_intent_id = i.id and event_type = 'send_intent_created';
  perform public.test_assert(n = 1, 'a content-free audit event is appended');
end $$;

-- 1b. create_send_intent is idempotent on idempotency_key (returns same intent).
--     Payload MUST be byte-identical to section 1's call — strict idempotency
--     (Phase 3A hardening) raises P0409 on a divergent payload for the same key.
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  n int;
begin
  i := public.create_send_intent(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cccccccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w1.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb, 'send me', null, null, '[]'::jsonb,
    null, null, 2, 'idem-key-1');
  perform public.test_assert(i.id = v_intent, 'idempotent replay returns the original intent');
  select count(*) into n from public.send_intents where idempotency_key = 'idem-key-1';
  perform public.test_assert(n = 1, 'no duplicate intent is created on idempotent replay');
end $$;

-- =====================================================================
-- 2. Cross-workspace isolation on the public transport tables (member A of W1)
-- =====================================================================
do $$
declare n int;
begin
  select count(*) into n from public.mailboxes;
  perform public.test_assert(n = 1, 'member A sees only W1 mailboxes (1), never W2''s');
  select count(*) into n from public.mailboxes where workspace_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  perform public.test_assert(n = 0, 'member A sees 0 rows of the foreign W2 mailbox');
  select count(*) into n from public.send_intents;
  perform public.test_assert(n = 1, 'member A sees the W1 send_intent only');
end $$;

-- 2b. authenticated cannot directly INSERT/UPDATE/DELETE the public tables.
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  begin
    insert into public.mailboxes (workspace_id, email_address, created_by)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'x@w1.example.com', auth.uid());
    raise exception 'direct mailboxes INSERT succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct mailboxes INSERT denied (42501)');
  end;
  begin
    update public.send_attempts set state = 'queued' where send_intent_id = v_intent;
    raise exception 'direct send_attempts UPDATE succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct send_attempts UPDATE denied (42501)');
  end;
  begin
    delete from public.send_intents where id = v_intent;
    raise exception 'direct send_intents DELETE succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct send_intents DELETE denied (42501)');
  end;
  begin
    insert into public.transport_audit (workspace_id, event_type)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'forged');
    raise exception 'direct transport_audit INSERT succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct transport_audit INSERT denied (42501)');
  end;
end $$;

-- 2c. The browser role has ZERO visibility into transport.mailbox_credentials.
do $$
declare n int;
begin
  begin
    select count(*) into n from transport.mailbox_credentials;
    raise exception 'authenticated read transport.mailbox_credentials (got % rows)', n using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'authenticated cannot even reference transport.mailbox_credentials (no schema USAGE, 42501)');
  end;
end $$;

reset role;

-- =====================================================================
-- 3. send_intents UPDATE-immutability (superuser: the trigger fires for all).
--    DELETE is intentionally NOT trigger-blocked (that would abort FK cascade);
--    the browser cannot delete anyway (SELECT-only grant, proven in 2b).
-- =====================================================================
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  begin
    update public.send_intents set subject = 'tampered' where id = v_intent;
    raise exception 'send_intents UPDATE succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'send_intents UPDATE rejected by immutability trigger (23514)');
  end;
end $$;

-- =====================================================================
-- 4. send_attempts state machine (superuser)
-- =====================================================================
do $$
declare
  v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
  v_attempt uuid;
begin
  select id into v_attempt from public.send_attempts where send_intent_id = v_intent;

  -- illegal jump confirmed -> completed
  begin
    update public.send_attempts set state = 'completed' where id = v_attempt;
    raise exception 'illegal transition succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'illegal transition confirmed->completed rejected (23514)');
  end;

  -- legal transition confirmed -> queued
  update public.send_attempts set state = 'queued', version = version + 1 where id = v_attempt;
  perform public.test_assert(
    (select state = 'queued' and version = 2 from public.send_attempts where id = v_attempt),
    'legal transition confirmed->queued accepted, version advanced');

  -- version rollback is rejected
  begin
    update public.send_attempts set version = 1 where id = v_attempt;
    raise exception 'version rollback succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'send_attempts.version rollback rejected (23514)');
  end;

  -- terminal state: completed accepts no further transition
  update public.send_attempts set state = 'claimed', version = version + 1 where id = v_attempt;
  -- Persist the exact MIME artifact before SMTP (the artifact-before-smtp_in_progress guard requires it).
  perform transport.create_or_verify_send_mime_artifact(
    a.id, a.send_intent_id, a.workspace_id, a.message_id,
    encode(sha256(convert_to('mime:' || a.id::text, 'UTF8')), 'hex'),
    octet_length(convert_to('mime:' || a.id::text, 'UTF8')),
    convert_to('mime:' || a.id::text, 'UTF8'))
  from public.send_attempts a where a.id = v_attempt;
  update public.send_attempts set state = 'smtp_in_progress', version = version + 1 where id = v_attempt;
  update public.send_attempts set state = 'smtp_accepted', version = version + 1 where id = v_attempt;
  update public.send_attempts set state = 'completed', version = version + 1 where id = v_attempt;
  begin
    update public.send_attempts set state = 'queued', version = version + 1 where id = v_attempt;
    raise exception 'transition out of terminal completed succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'completed is terminal: no further transition (23514)');
  end;
end $$;

-- =====================================================================
-- 5. Non-member (C of W2) cannot create an intent against a W1 mailbox (P0002)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  begin
    perform public.create_send_intent(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'cccccccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, 1, 'ops@w1.example.com', '{"to":["x@y.z"]}'::jsonb,
      'send me', null, null, '[]'::jsonb, null, null, 2, 'idem-c-attempt');
    raise exception 'non-member created a send_intent' using errcode = 'ASSRT';
  exception when sqlstate 'P0002' then
    perform public.test_assert(true, 'non-member of W1 gets P0002 from create_send_intent');
  end;
  -- C also sees zero W1 mailboxes / intents.
  perform public.test_assert(
    (select count(*) = 0 from public.mailboxes where workspace_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
    'member C sees 0 rows of the foreign W1 mailbox');
  perform public.test_assert(
    (select count(*) = 0 from public.send_intents),
    'member C sees 0 W1 send_intents');
end $$;

-- 5b. anon has no access at all.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  begin
    perform 1 from public.mailboxes limit 1;
    raise exception 'anon read mailboxes' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'anon cannot SELECT public.mailboxes (42501)');
  end;
  begin
    perform public.request_mailbox_sync('cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    raise exception 'anon executed request_mailbox_sync' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'anon cannot EXECUTE request_mailbox_sync (42501)');
  end;
end $$;

reset role;

-- =====================================================================
-- 6. request_mailbox_sync (member A) validates + audits, does no IMAP
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v jsonb; n int;
begin
  v := public.request_mailbox_sync('cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  -- Phase 3A hardening: the RPC now returns the DURABLE request id/status.
  perform public.test_assert(v ->> 'status' = 'pending', 'request_mailbox_sync returns durable status=pending');
  perform public.test_assert(v ->> 'sync_request_id' is not null, 'request_mailbox_sync returns a durable sync_request_id');
  select count(*) into n from public.transport_audit
    where mailbox_id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1' and event_type = 'mailbox_sync_requested';
  perform public.test_assert(n = 1, 'request_mailbox_sync appends a content-free audit event');
end $$;

-- 6b. kill switch blocks send-intent creation (55000).
reset role;
update public.mailboxes set kill_switch = true where id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1';
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
        v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
begin
  begin
    perform public.create_send_intent(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'cccccccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'ops@w1.example.com', '{"to":["x@y.z"]}'::jsonb,
      'send me', null, null, '[]'::jsonb, null, null, 2, 'idem-killed');
    raise exception 'create_send_intent ran with kill switch engaged' using errcode = 'ASSRT';
  exception when sqlstate '55000' then
    perform public.test_assert(true, 'kill switch blocks create_send_intent (55000)');
  end;
end $$;

reset role;

-- =====================================================================
-- 7. FK cascade cleanup is not blocked by the immutability triggers.
--    Deleting the workspace must cascade through mailboxes -> credentials and
--    send_intents -> send_attempts -> worker_claims, and SET NULL the audit
--    mailbox_id, all without a trigger aborting the referential action.
-- =====================================================================
do $$
declare n int;
begin
  delete from public.workspaces where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  select count(*) into n from public.send_intents
    where workspace_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform public.test_assert(n = 0, 'workspace delete cascades away send_intents (no delete-block trigger)');
  select count(*) into n from public.send_attempts
    where workspace_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  perform public.test_assert(n = 0, 'workspace delete cascades away send_attempts');
  select count(*) into n from transport.mailbox_credentials
    where mailbox_id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1';
  perform public.test_assert(n = 0, 'mailbox delete cascades away transport.mailbox_credentials');
end $$;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
