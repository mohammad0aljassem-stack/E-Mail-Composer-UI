-- ============================================================================
-- Phase 2 database tests — exact privilege matrix
--
-- Asserts the precise has_table_privilege / has_function_privilege matrix for
-- anon, authenticated and service_role across all six Phase 2 tables and every
-- RPC. Runs as the superuser (catalog inspection). Any deviation fails.
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

-- 1. Table privilege matrix: 3 roles x 6 tables x 7 privileges = 126 assertions.
do $$
declare
  r record;
  actual boolean;
  expected boolean;
begin
  for r in
    select roles.role, tbls.tbl, privs.priv
    from (values ('anon'),('authenticated'),('service_role')) roles(role)
    cross join (values ('drafts'),('draft_versions'),('draft_templates'),
                       ('draft_template_versions'),('signatures'),('draft_attachments')) tbls(tbl)
    cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),
                       ('TRUNCATE'),('REFERENCES'),('TRIGGER')) privs(priv)
  loop
    actual := has_table_privilege(r.role, ('public.' || r.tbl)::regclass, r.priv);
    expected := case
      when r.role = 'service_role' then true
      when r.role = 'anon' then false
      else  -- authenticated
        case
          when r.priv = 'SELECT' then true
          when r.tbl = 'draft_templates' and r.priv in ('INSERT','UPDATE') then true
          when r.tbl = 'signatures' and r.priv in ('INSERT','UPDATE','DELETE') then true
          else false
        end
    end;
    perform public.test_assert(
      actual = expected,
      format('%s %s on public.%s = %s', r.role, r.priv, r.tbl, expected));
  end loop;
end $$;

-- 2. Function EXECUTE matrix for every RPC (authenticated + service_role yes; anon no).
do $$
declare
  r record;
begin
  for r in
    select fn, sig from (values
      ('create_draft',            'uuid, text, jsonb'),
      ('save_draft',              'uuid, uuid, bigint, text, jsonb, text, uuid, uuid'),
      ('checkpoint_draft',        'uuid, uuid, bigint, text'),
      ('restore_draft_version',   'uuid, uuid, uuid, bigint'),
      ('archive_draft',           'uuid, uuid, bigint'),
      ('create_template_version', 'uuid, uuid, text, jsonb, jsonb'),
      ('set_default_signature',   'uuid'),
      ('create_attachment_intent','uuid, uuid, text, text, bigint, text'),
      ('finalize_attachment',     'uuid, uuid, text'),
      ('mark_attachment_deleted', 'uuid, uuid')
    ) t(fn, sig)
  loop
    perform public.test_assert(
      has_function_privilege('authenticated', format('public.%s(%s)', r.fn, r.sig), 'EXECUTE'),
      format('authenticated may EXECUTE %s', r.fn));
    perform public.test_assert(
      has_function_privilege('service_role', format('public.%s(%s)', r.fn, r.sig), 'EXECUTE'),
      format('service_role may EXECUTE %s', r.fn));
    perform public.test_assert(
      not has_function_privilege('anon', format('public.%s(%s)', r.fn, r.sig), 'EXECUTE'),
      format('anon may NOT EXECUTE %s', r.fn));
  end loop;
end $$;

-- 3. Internal helper functions are not callable by anon or authenticated.
do $$
begin
  perform public.test_assert(
    not has_function_privilege('authenticated', 'public.phase2_safe_filename(text)', 'EXECUTE'),
    'authenticated may NOT EXECUTE phase2_safe_filename');
  perform public.test_assert(
    not has_function_privilege('anon', 'public.phase2_safe_filename(text)', 'EXECUTE'),
    'anon may NOT EXECUTE phase2_safe_filename');
  perform public.test_assert(
    not has_function_privilege('authenticated', 'public.phase2_validate_variable_schema(jsonb)', 'EXECUTE'),
    'authenticated may NOT EXECUTE phase2_validate_variable_schema');
  perform public.test_assert(
    has_function_privilege('service_role', 'public.phase2_validate_variable_schema(jsonb)', 'EXECUTE'),
    'service_role may EXECUTE phase2_validate_variable_schema');
end $$;

-- 4. Mutation RPCs are SECURITY DEFINER with a pinned empty search_path;
--    set_default_signature stays SECURITY INVOKER by design (owner-writable table).
do $$
declare r record; expect_secdef boolean;
begin
  for r in
    select proname, prosecdef, proconfig
    from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('create_draft','save_draft','checkpoint_draft','restore_draft_version',
                      'archive_draft','create_template_version','set_default_signature',
                      'create_attachment_intent','finalize_attachment','mark_attachment_deleted')
  loop
    expect_secdef := (r.proname <> 'set_default_signature');
    perform public.test_assert(r.prosecdef = expect_secdef,
      format('%s prosecdef = %s', r.proname, expect_secdef));
    perform public.test_assert(
      (select bool_or(c like 'search_path=%') from unnest(r.proconfig) c),
      format('%s pins an empty search_path', r.proname));
  end loop;
end $$;

drop function if exists public.test_assert(boolean, text);
