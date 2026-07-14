-- ============================================================================
-- Phase 3A database tests — REAL transport_worker send_attempts transitions
--
-- Proves the load-bearing claim of migration
-- 20260715100000_worker_transition_grant: a least-privilege `transport_worker`
-- (exactly SELECT,UPDATE on public.send_attempts, no test-only grant) can drive
-- the outbound state machine because the CANONICAL schema grants it EXECUTE on
-- the transition-table validator that the SECURITY INVOKER BEFORE UPDATE trigger
-- calls on its behalf.
--
-- The privilege is asserted to originate from the migration, NOT from the test
-- harness: neither this file nor scripts/test-db.sh adds
-- `GRANT EXECUTE ... TO transport_worker`. If that grant were missing, every
-- `set local role transport_worker` UPDATE below would fail with
-- `permission denied for function phase3_send_attempt_transition_ok` (42501),
-- so section 1 succeeding IS the proof the trigger invoked the validator as the
-- worker role.
--
-- Everything runs inside a single transaction that is rolled back, so the suite
-- leaves no rows behind and is order-independent w.r.t. the other suites.
--
-- Run with: psql -v ON_ERROR_STOP=1 -f <this>. Each passing assertion emits
-- NOTICE ok - <message>.
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
-- The worker role calls test_assert from inside its role-scoped DO blocks.
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
-- Isolated fixture (superuser): a workspace/user/member/mailbox, then a valid
-- send_intent + seeded send_attempt (state=confirmed) created via the real RPC.
-- Distinct UUIDs (dddd/eeee) avoid colliding with the other suites' seeds.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'wanda@example.com', '{"full_name":"Wanda"}');
insert into public.workspaces (id, name) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'Worker Workspace');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'owner');
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('eeeeeeee-cccc-cccc-cccc-ccccccccccc1', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
   'ops@worker.example.com', true, 'dddddddd-dddd-dddd-dddd-dddddddddddd');

-- Create a draft + send_intent as the member (SECURITY DEFINER RPCs).
select set_config('request.jwt.claims',
  '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  d public.drafts;
  i public.send_intents;
  v_attempt uuid;
begin
  d := public.create_draft('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'worker draft', public.test_doc('body'));
  i := public.create_send_intent(
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
    'eeeeeeee-cccc-cccc-cccc-ccccccccccc1',
    d.id, d.revision,
    'ops@worker.example.com',
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'worker draft', null, null, '[]'::jsonb,
    null, null, 2, 'worker-idem-1');
  select id into v_attempt from public.send_attempts where send_intent_id = i.id;
  insert into t_ctx values ('intent', i.id::text), ('attempt', v_attempt::text);
end $$;
reset role;

-- =====================================================================
-- 1. transport_worker holds the validator EXECUTE from the CANONICAL schema.
--    (Catalog check as superuser; the sole source is the migration, not the
--    harness — see the header.)
-- =====================================================================
do $$
begin
  perform public.test_assert(
    has_function_privilege('transport_worker',
      'public.phase3_send_attempt_transition_ok(text, text)', 'EXECUTE'),
    'transport_worker holds validator EXECUTE from the canonical migration (not the harness)');
end $$;

-- =====================================================================
-- 2. As the REAL worker role: a legal transition confirmed->queued succeeds.
--    (If the validator EXECUTE were missing, the INVOKER trigger would 42501.)
-- =====================================================================
set local role transport_worker;
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  update public.send_attempts set state = 'queued', version = version + 1 where id = v_attempt;
  perform public.test_assert(
    (select state = 'queued' and version = 2 from public.send_attempts where id = v_attempt),
    'worker: legal transition confirmed->queued accepted (INVOKER trigger ran validator as worker)');
end $$;

-- 3. As the worker: a field-only update (state unchanged) also passes the
--    validator (p_from = p_to branch), proving the validator is genuinely
--    invoked and returns true for the worker on every UPDATE.
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  update public.send_attempts set version = version + 1 where id = v_attempt;  -- queued->queued
  perform public.test_assert(
    (select state = 'queued' and version = 3 from public.send_attempts where id = v_attempt),
    'worker: field-only update (queued->queued) passes the validator, version advanced');
end $$;

-- 4. As the worker: an ILLEGAL transition is rejected with the foundation's
--    SQLSTATE 23514 (not 42501 — the validator ran and returned false).
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

-- 5. As the worker: version rollback is still rejected (23514).
do $$
declare v_attempt uuid := (select val from t_ctx where key = 'attempt')::uuid;
begin
  begin
    update public.send_attempts set version = 1 where id = v_attempt;  -- 3 -> 1
    raise exception 'version rollback succeeded' using errcode = 'ASSRT';
  exception when sqlstate '23514' then
    perform public.test_assert(true, 'worker: version rollback rejected (23514)');
  end;
end $$;

-- 6. As the worker: workspace_id is immutable (23514).
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

-- 7. As the worker: send_intent_id is immutable (23514).
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

-- 8. As the worker: drive the legal chain to a terminal state, then prove the
--    terminal state stays terminal (completed->queued rejected, 23514). Every
--    intermediate UPDATE runs as the worker and exercises the validator.
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

-- 9. As the worker: it may NOT update send_intents (SELECT-only grant; 42501).
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

-- 10. Browser role (authenticated) still cannot update send_attempts (42501) —
--     the worker grant did not widen the browser's privileges.
select set_config('request.jwt.claims',
  '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_intent uuid := (select val from t_ctx where key = 'intent')::uuid;
begin
  begin
    update public.send_attempts set state = 'cancelled' where send_intent_id = v_intent;
    raise exception 'authenticated updated send_attempts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'authenticated (browser) still cannot UPDATE public.send_attempts (42501)');
  end;
end $$;
reset role;

-- =====================================================================
-- 11. Idempotency: re-applying the migration's exact statements (revoke-then-
--     grant) a further time is harmless and leaves the grant matrix unchanged.
--     scripts/test-db.sh already applies the migration twice before the tests
--     run; here we re-execute the statements a third time and re-assert.
-- =====================================================================
revoke execute on function public.phase3_send_attempt_transition_ok(text, text)
  from public, anon, authenticated;
grant execute on function public.phase3_send_attempt_transition_ok(text, text)
  to transport_worker;
do $$
declare
  v_sig text := 'public.phase3_send_attempt_transition_ok(text, text)';
begin
  -- 17. re-apply harmless: worker still holds EXECUTE.
  perform public.test_assert(
    has_function_privilege('transport_worker', v_sig, 'EXECUTE'),
    'idempotent re-apply: transport_worker still has validator EXECUTE');
  -- 18. service_role EXECUTE unchanged.
  perform public.test_assert(
    has_function_privilege('service_role', v_sig, 'EXECUTE'),
    'idempotent re-apply: service_role still has validator EXECUTE');
  -- 19. browser roles still have NO EXECUTE after the re-apply.
  perform public.test_assert(
    not has_function_privilege('public', v_sig, 'EXECUTE')
      and not has_function_privilege('anon', v_sig, 'EXECUTE')
      and not has_function_privilege('authenticated', v_sig, 'EXECUTE'),
    'idempotent re-apply: public/anon/authenticated still have NO validator EXECUTE');
end $$;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
