-- ============================================================================
-- Phase 3A database tests — canonical transport-contract privilege proofs
--
-- Proves, against the REAL loaded migration chain and the REAL roles, exactly
-- the privilege boundaries declared by the canonical manifest
-- (supabase/contracts/phase3-transport-contract.json):
--
--   requiredFunctionPrivileges  transport_worker  EXECUTE  validator
--   forbiddenFunctionPrivileges public/anon/authenticated NO EXECUTE validator
--   protectedPrivateSchemas     anon/authenticated NO USAGE on schema transport
--   requiredTablePrivileges     transport_worker SELECT+UPDATE transport.sync_requests
--   forbiddenTablePrivileges    transport_worker NO INSERT/DELETE transport.sync_requests
--
-- and, behaviorally, that a least-privilege `transport_worker` (no test-only
-- grant of any kind) can drive a legal send_attempts transition through the
-- SECURITY INVOKER BEFORE UPDATE trigger, while every illegal transition,
-- version rollback, terminal-state escape, and immutable-column change is
-- rejected with 23514, and a worker UPDATE of send_intents is rejected with
-- 42501.
--
-- IMPORTANT: this file adds NO `GRANT ... TO transport_worker` of any object.
-- The only harness grant is EXECUTE on the assertion helpers to PUBLIC (so the
-- role-scoped DO blocks can call them), matching the existing suites. If the
-- migration chain did not already grant the worker EXECUTE on the validator,
-- section 5's very first UPDATE would fail 42501 — so its success IS the proof
-- the privilege originates from the canonical schema, not this test.
--
-- Runs inside a single rolled-back transaction; leaves no rows behind.
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
-- Harness helper only, granted to PUBLIC (NOT a contract grant to any worker
-- object). Lets the role-scoped DO blocks below call the assertion helper.
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

-- =====================================================================
-- Section 1 — requiredFunctionPrivileges + forbiddenFunctionPrivileges
--   validator: public.phase3_send_attempt_transition_ok(text,text)
-- =====================================================================
do $$
declare
  v_sig text := 'public.phase3_send_attempt_transition_ok(text, text)';
begin
  -- requiredFunctionPrivileges: worker holds EXECUTE (from the canonical chain).
  perform public.test_assert(
    has_function_privilege('transport_worker', v_sig, 'EXECUTE'),
    'manifest requiredFunctionPrivileges: transport_worker EXECUTE validator');
  -- forbiddenFunctionPrivileges: browser roles must NOT execute the validator.
  perform public.test_assert(
    not has_function_privilege('public', v_sig, 'EXECUTE'),
    'manifest forbiddenFunctionPrivileges: public NO EXECUTE validator');
  perform public.test_assert(
    not has_function_privilege('anon', v_sig, 'EXECUTE'),
    'manifest forbiddenFunctionPrivileges: anon NO EXECUTE validator');
  perform public.test_assert(
    not has_function_privilege('authenticated', v_sig, 'EXECUTE'),
    'manifest forbiddenFunctionPrivileges: authenticated NO EXECUTE validator');
end $$;

-- =====================================================================
-- Section 2 — protectedPrivateSchemas: no browser USAGE on schema transport.
-- =====================================================================
do $$
begin
  perform public.test_assert(
    not has_schema_privilege('anon', 'transport', 'USAGE'),
    'manifest protectedPrivateSchemas: anon NO USAGE on schema transport');
  perform public.test_assert(
    not has_schema_privilege('authenticated', 'transport', 'USAGE'),
    'manifest protectedPrivateSchemas: authenticated NO USAGE on schema transport');
end $$;

-- =====================================================================
-- Section 3 — requiredTablePrivileges: transport_worker SELECT+UPDATE on
--             transport.sync_requests.
-- =====================================================================
do $$
begin
  perform public.test_assert(
    has_table_privilege('transport_worker', 'transport.sync_requests'::regclass, 'SELECT'),
    'manifest requiredTablePrivileges: transport_worker SELECT on transport.sync_requests');
  perform public.test_assert(
    has_table_privilege('transport_worker', 'transport.sync_requests'::regclass, 'UPDATE'),
    'manifest requiredTablePrivileges: transport_worker UPDATE on transport.sync_requests');
end $$;

-- =====================================================================
-- Section 4 — forbiddenTablePrivileges: transport_worker NO INSERT/DELETE on
--             transport.sync_requests (the DEFINER RPC inserts; worker claims).
-- =====================================================================
do $$
begin
  perform public.test_assert(
    not has_table_privilege('transport_worker', 'transport.sync_requests'::regclass, 'INSERT'),
    'manifest forbiddenTablePrivileges: transport_worker NO INSERT on transport.sync_requests');
  perform public.test_assert(
    not has_table_privilege('transport_worker', 'transport.sync_requests'::regclass, 'DELETE'),
    'manifest forbiddenTablePrivileges: transport_worker NO DELETE on transport.sync_requests');
end $$;

-- ---------------------------------------------------------------------------
-- Fixture (superuser): a workspace/user/member/mailbox, then a real
-- send_intent + seeded send_attempt (state=confirmed) via the real RPC.
-- Distinct UUIDs (all 'f'/'c' based) avoid colliding with the other suites.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'fran@example.com', '{"full_name":"Fran"}');
insert into public.workspaces (id, name) values
  ('ffffeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'Contract Workspace');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('ffffeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'ffffffff-ffff-ffff-ffff-ffffffffffff', 'owner');
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('ffffcccc-cccc-cccc-cccc-ccccccccccc1', 'ffffeeee-eeee-eeee-eeee-eeeeeeeeeeee',
   'ops@contract.example.com', true, 'ffffffff-ffff-ffff-ffff-ffffffffffff');

select set_config('request.jwt.claims',
  '{"sub":"ffffffff-ffff-ffff-ffff-ffffffffffff","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  d public.drafts;
  i public.send_intents;
  v_attempt uuid;
begin
  d := public.create_draft('ffffeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'contract draft', public.test_doc('body'));
  i := public.create_send_intent(
    'ffffeeee-eeee-eeee-eeee-eeeeeeeeeeee',
    'ffffcccc-cccc-cccc-cccc-ccccccccccc1',
    d.id, d.revision,
    'ops@contract.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'contract draft', null, null, '[]'::jsonb,
    null, null, 2, 'contract-idem-1');
  select id into v_attempt from public.send_attempts where send_intent_id = i.id;
  insert into t_ctx values ('intent', i.id::text), ('attempt', v_attempt::text);
end $$;
reset role;

-- =====================================================================
-- Section 5 — REAL worker transitions through the SECURITY INVOKER trigger,
--             with NO test-only grant. Legal transition succeeds; illegal
--             transition / version rollback / terminal-state / workspace_id /
--             send_intent_id changes fail 23514; worker UPDATE of send_intents
--             fails 42501.
-- =====================================================================
set local role transport_worker;

-- 5.1 legal transition confirmed->queued succeeds (proves the INVOKER trigger
--     ran the validator as the worker role; a missing grant would be 42501).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  update public.send_attempts set state = 'queued', version = version + 1 where id = v_attempt;
  perform public.test_assert(
    (select state = 'queued' and version = 2 from public.send_attempts where id = v_attempt),
    'worker: legal transition confirmed->queued accepted via INVOKER trigger (no test-only grant)');
end $$;

-- 5.2 illegal transition rejected with 23514 (validator ran, returned false).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  begin
    update public.send_attempts set state = 'completed', version = version + 1 where id = v_attempt;
    raise exception 'illegal transition succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'worker: illegal transition queued->completed rejected (23514)');
  end;
end $$;

-- 5.3 version rollback rejected (23514).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  begin
    update public.send_attempts set version = 1 where id = v_attempt;
    raise exception 'version rollback succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'worker: version rollback rejected (23514)');
  end;
end $$;

-- 5.4 workspace_id is immutable (23514).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  begin
    update public.send_attempts
      set workspace_id = '00000000-0000-0000-0000-000000000000', version = version + 1
      where id = v_attempt;
    raise exception 'workspace_id mutation succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'worker: send_attempts.workspace_id is immutable (23514)');
  end;
end $$;

-- 5.5 send_intent_id is immutable (23514).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  begin
    update public.send_attempts
      set send_intent_id = '00000000-0000-0000-0000-000000000000', version = version + 1
      where id = v_attempt;
    raise exception 'send_intent_id mutation succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'worker: send_attempts.send_intent_id is immutable (23514)');
  end;
end $$;

-- 5.6 drive the legal chain to a terminal state, then prove terminal stays
--     terminal (completed->queued rejected, 23514).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  update public.send_attempts set state = 'claimed',          version = version + 1 where id = v_attempt;
  -- Persist the exact MIME artifact before SMTP (the artifact-before-smtp_in_progress guard requires it).
  perform transport.create_or_verify_send_mime_artifact(
    a.id, a.send_intent_id, a.workspace_id, a.message_id,
    encode(sha256(convert_to('mime:' || a.id::text, 'UTF8')), 'hex'),
    octet_length(convert_to('mime:' || a.id::text, 'UTF8')),
    convert_to('mime:' || a.id::text, 'UTF8'))
  from public.send_attempts a where a.id = v_attempt;
  update public.send_attempts set state = 'smtp_in_progress', version = version + 1 where id = v_attempt;
  update public.send_attempts set state = 'smtp_accepted',    version = version + 1 where id = v_attempt;
  update public.send_attempts set state = 'completed',        version = version + 1 where id = v_attempt;
  begin
    update public.send_attempts set state = 'queued', version = version + 1 where id = v_attempt;
    raise exception 'transition out of terminal completed succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'worker: completed is terminal — no further transition (23514)');
  end;
end $$;

-- 5.7 worker may NOT update send_intents (SELECT-only grant; 42501).
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  begin
    update public.send_intents set subject = 'worker tampered' where id = v_intent;
    raise exception 'worker updated send_intents' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'worker: cannot UPDATE public.send_intents (42501)');
  end;
end $$;

reset role;

-- =====================================================================
-- Section 6 — protectedPrivateSchemas (behavioral): a browser role cannot
--             SELECT or UPDATE a transport.* table (no schema USAGE => 42501).
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"ffffffff-ffff-ffff-ffff-ffffffffffff","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform 1 from transport.sync_requests limit 1;
    raise exception 'authenticated SELECTed transport.sync_requests' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'authenticated (browser) cannot SELECT transport.sync_requests (42501)');
  end;
  begin
    update transport.sync_requests set status = 'failed' where false;
    raise exception 'authenticated UPDATEd transport.sync_requests' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'authenticated (browser) cannot UPDATE transport.sync_requests (42501)');
  end;
end $$;
reset role;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
