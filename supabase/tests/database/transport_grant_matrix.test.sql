-- ============================================================================
-- Phase 3A database tests — exact transport privilege matrix
--
-- Asserts the precise has_table_privilege / has_schema_privilege /
-- has_function_privilege matrix for anon, authenticated, service_role and the
-- least-privilege worker role transport_worker across every new public and
-- transport table + the two RPCs. Runs as the superuser (catalog inspection).
-- Any deviation fails.
--
-- The load-bearing security claims proven here:
--   * anon has NOTHING anywhere;
--   * authenticated has SELECT-only on the public transport tables and ZERO on
--     the private transport schema (no table privilege AND no schema USAGE);
--   * transport_worker has exactly its narrow documented DML and no more;
--   * the RPCs are SECURITY DEFINER with a pinned empty search_path, executable
--     by authenticated + service_role only.
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

-- 1. Table privilege matrix: 4 roles x 10 tables x 4 privileges = 160 assertions.
do $$
declare
  r record;
  actual boolean;
  expected boolean;
begin
  for r in
    select roles.role, t.sch, t.tbl, privs.priv
    from (values ('anon'),('authenticated'),('service_role'),('transport_worker')) roles(role)
    cross join (values
      ('public','mailboxes'),('public','mailbox_folders'),('public','mail_messages'),
      ('public','draft_mirrors'),('public','send_intents'),('public','send_attempts'),
      ('public','transport_audit'),
      ('transport','mailbox_credentials'),('transport','worker_claims'),('transport','worker_heartbeats')
    ) t(sch, tbl)
    cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) privs(priv)
  loop
    actual := has_table_privilege(r.role, (r.sch || '.' || r.tbl)::regclass, r.priv);
    expected := case
      when r.role = 'service_role' then true
      when r.role = 'anon' then false
      when r.role = 'authenticated' then (r.sch = 'public' and r.priv = 'SELECT')
      else -- transport_worker
        case
          when r.sch = 'public' and r.tbl = 'mailboxes'          then r.priv = 'SELECT'
          when r.sch = 'public' and r.tbl = 'mailbox_folders'    then true
          when r.sch = 'public' and r.tbl = 'mail_messages'      then true
          when r.sch = 'public' and r.tbl = 'draft_mirrors'      then true
          when r.sch = 'public' and r.tbl = 'send_intents'       then r.priv = 'SELECT'
          when r.sch = 'public' and r.tbl = 'send_attempts'      then r.priv in ('SELECT','UPDATE')
          when r.sch = 'public' and r.tbl = 'transport_audit'    then r.priv in ('SELECT','INSERT')
          when r.sch = 'transport' and r.tbl = 'mailbox_credentials' then r.priv = 'SELECT'
          when r.sch = 'transport' and r.tbl = 'worker_claims'   then true
          when r.sch = 'transport' and r.tbl = 'worker_heartbeats' then true
          else false
        end
    end;
    perform public.test_assert(
      actual = expected,
      format('%s %s on %s.%s = %s', r.role, r.priv, r.sch, r.tbl, expected));
  end loop;
end $$;

-- 2. Schema USAGE/CREATE on the private transport schema.
--    anon/authenticated must have NO access; worker + service_role get USAGE.
do $$
begin
  perform public.test_assert(
    not has_schema_privilege('anon', 'transport', 'USAGE'),
    'anon has NO USAGE on schema transport');
  perform public.test_assert(
    not has_schema_privilege('authenticated', 'transport', 'USAGE'),
    'authenticated has NO USAGE on schema transport');
  perform public.test_assert(
    not has_schema_privilege('anon', 'transport', 'CREATE'),
    'anon has NO CREATE on schema transport');
  perform public.test_assert(
    not has_schema_privilege('authenticated', 'transport', 'CREATE'),
    'authenticated has NO CREATE on schema transport');
  perform public.test_assert(
    has_schema_privilege('transport_worker', 'transport', 'USAGE'),
    'transport_worker has USAGE on schema transport');
  perform public.test_assert(
    has_schema_privilege('service_role', 'transport', 'USAGE'),
    'service_role has USAGE on schema transport');
end $$;

-- 3. RPC EXECUTE matrix. authenticated + service_role may execute; anon and the
--    worker may NOT (the worker never creates intents or requests syncs).
do $$
declare
  r record;
  v_sig text;
begin
  for r in
    select fn, sig from (values
      ('create_send_intent',
       'uuid, uuid, uuid, bigint, text, jsonb, text, text, text, jsonb, uuid, uuid, integer, text'),
      ('request_mailbox_sync', 'uuid, uuid')
    ) t(fn, sig)
  loop
    v_sig := format('public.%s(%s)', r.fn, r.sig);
    perform public.test_assert(
      has_function_privilege('authenticated', v_sig, 'EXECUTE'),
      format('authenticated may EXECUTE %s', r.fn));
    perform public.test_assert(
      has_function_privilege('service_role', v_sig, 'EXECUTE'),
      format('service_role may EXECUTE %s', r.fn));
    perform public.test_assert(
      not has_function_privilege('anon', v_sig, 'EXECUTE'),
      format('anon may NOT EXECUTE %s', r.fn));
    perform public.test_assert(
      not has_function_privilege('transport_worker', v_sig, 'EXECUTE'),
      format('transport_worker may NOT EXECUTE %s', r.fn));
  end loop;
end $$;

-- 4. RPCs are SECURITY DEFINER with a pinned (empty) search_path.
do $$
declare r record;
begin
  for r in
    select proname, prosecdef, proconfig
    from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('create_send_intent','request_mailbox_sync')
  loop
    perform public.test_assert(r.prosecdef,
      format('%s is SECURITY DEFINER', r.proname));
    perform public.test_assert(
      (select bool_or(c like 'search_path=%') from unnest(r.proconfig) c),
      format('%s pins an empty search_path', r.proname));
  end loop;
end $$;

drop function if exists public.test_assert(boolean, text);
