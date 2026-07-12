-- ============================================================================
-- Phase 2 database tests — direct-write regression probes
--
-- Proves the vulnerability is closed: an authenticated workspace MEMBER cannot
-- reach any RPC-only invariant through direct PostgREST table DML, and cannot
-- forge storage uploads. Every probe below must be DENIED. anon has no access
-- at all. Each passing assertion emits: NOTICE ok - <message>.
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
grant execute on function public.test_assert(boolean, text) to public;

create or replace function public.test_doc(p_text text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('type','doc','content', jsonb_build_array(
    jsonb_build_object('type','paragraph','content', jsonb_build_array(
      jsonb_build_object('type','text','text',p_text)))));
$$;
grant execute on function public.test_doc(text) to public;

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

-- ===== authenticated member A of W1 =====
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;

-- Seed a draft + a pending attachment intent through the legitimate RPC path.
do $$
declare d public.drafts; a public.draft_attachments;
begin
  d := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'regression', public.test_doc('x'));
  insert into t_ctx values ('draft', d.id::text);
  a := public.create_attachment_intent(d.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'note.txt', 'text/plain', 100);
  insert into t_ctx values ('att', a.id::text), ('att_path', a.storage_path);
end $$;

-- 1. drafts direct UPDATE is denied at the privilege level (unchanged / +1 / +10).
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  begin
    update public.drafts set subject = 'hax' where id = v_draft;
    raise exception 'direct drafts UPDATE (unchanged rev) succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct drafts UPDATE denied (permission denied, 42501)');
  end;
  begin
    update public.drafts set subject = 'hax', revision = revision + 1 where id = v_draft;
    raise exception 'direct drafts UPDATE (+1 rev) succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct drafts UPDATE with revision+1 denied (42501)');
  end;
  begin
    update public.drafts set revision = revision + 10 where id = v_draft;
    raise exception 'direct drafts UPDATE (+10 rev) succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct drafts UPDATE with revision+10 denied (42501)');
  end;
  begin
    delete from public.drafts where id = v_draft;
    raise exception 'direct drafts DELETE succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct drafts DELETE denied (42501)');
  end;
end $$;

-- 2. draft_versions direct INSERT is denied (append-only history is RPC-only).
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  begin
    insert into public.draft_versions
      (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
    values
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft, 99, 1, 'x', public.test_doc('x'), 'manual_checkpoint', auth.uid());
    raise exception 'direct draft_versions INSERT succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct draft_versions INSERT denied (42501)');
  end;
end $$;

-- 3. draft_template_versions direct INSERT is denied.
do $$
begin
  begin
    insert into public.draft_template_versions
      (workspace_id, template_id, version_no, subject_template, body_template_json, variable_schema, created_by)
    values
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 1, 's', public.test_doc('x'), '[]'::jsonb, auth.uid());
    raise exception 'direct draft_template_versions INSERT succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct draft_template_versions INSERT denied (42501)');
  end;
end $$;

-- 4. draft_attachments direct INSERT / UPDATE are denied (arbitrary, oversized,
--    and the status='ready' promotion all fail before any invariant runs).
do $$
declare v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
        v_att uuid := (select val from t_ctx where key = 'att')::uuid;
begin
  begin
    insert into public.draft_attachments
      (workspace_id, draft_id, storage_path, original_filename, safe_filename, mime_type, size_bytes, created_by)
    values
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft,
       'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || v_draft || '/' || gen_random_uuid() || '/x.txt',
       'x.txt', 'x.txt', 'text/plain', 100, auth.uid());
    raise exception 'direct draft_attachments INSERT (arbitrary) succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct draft_attachments INSERT denied (42501) — 11th row / bypass path is impossible');
  end;
  begin
    insert into public.draft_attachments
      (workspace_id, draft_id, storage_path, original_filename, safe_filename, mime_type, size_bytes, created_by)
    values
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_draft,
       'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || v_draft || '/' || gen_random_uuid() || '/big.pdf',
       'big.pdf', 'big.pdf', 'application/pdf', 999999999, auth.uid());
    raise exception 'direct draft_attachments INSERT (oversized) succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct draft_attachments INSERT of an oversized/over-quota row denied (42501)');
  end;
  begin
    update public.draft_attachments set status = 'ready', verified_at = now() where id = v_att;
    raise exception 'direct draft_attachments UPDATE to ready succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'direct draft_attachments UPDATE to status=ready denied (42501)');
  end;
end $$;

-- 5. Storage: the legitimate upload at the pending intent path IS allowed...
do $$
declare v_path text := (select val from t_ctx where key = 'att_path');
begin
  insert into storage.objects (bucket_id, name, metadata)
  values ('draft-attachments', v_path, jsonb_build_object('size', 100));
  perform public.test_assert(true, 'upload at the matching pending-intent path is allowed for the owning member');
end $$;

-- ...and once finalized (status=ready), a re-upload at that same path is denied.
do $$
declare v_att uuid := (select val from t_ctx where key = 'att')::uuid;
        a public.draft_attachments;
begin
  a := public.finalize_attachment(v_att, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  perform public.test_assert(a.status = 'ready', 'attachment finalized to ready for the re-upload probe');
end $$;

-- superuser removes the object so a re-insert is not blocked by the unique index;
-- the policy (no pending row anymore) must be what denies it.
reset role;
delete from storage.objects
where bucket_id = 'draft-attachments' and name = (select val from t_ctx where key = 'att_path');
set local role authenticated;

do $$
declare v_path text := (select val from t_ctx where key = 'att_path');
        v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
begin
  -- re-upload at the now-ready path: no pending row -> denied
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('draft-attachments', v_path, jsonb_build_object('size', 100));
    raise exception 'post-ready re-upload succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'storage re-upload at a finalized (ready) path is denied (no pending intent)');
  end;
  -- wrong workspace prefix (W2): no pending row -> denied
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('draft-attachments',
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/' || v_draft || '/' || gen_random_uuid() || '/x.txt',
      jsonb_build_object('size', 10));
    raise exception 'wrong-workspace upload succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'storage upload under a foreign workspace prefix is denied');
  end;
  -- wrong draft (right workspace, no matching pending row) -> denied
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('draft-attachments',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || gen_random_uuid() || '/' || gen_random_uuid() || '/x.txt',
      jsonb_build_object('size', 10));
    raise exception 'wrong-draft upload succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'storage upload for a non-matching draft path is denied');
  end;
  -- entirely arbitrary path -> denied
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('draft-attachments', 'arbitrary/path/to/secret.txt', jsonb_build_object('size', 10));
    raise exception 'arbitrary-path upload succeeded' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'storage upload at an arbitrary path is denied');
  end;
end $$;

-- 6. anon has no access to any Phase 2 table and no RPC EXECUTE privilege.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $$
begin
  begin
    perform 1 from public.drafts limit 1;
    raise exception 'anon read drafts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'anon cannot SELECT public.drafts (42501)');
  end;
  begin
    perform public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'x', public.test_doc('x'));
    raise exception 'anon executed create_draft' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'anon cannot EXECUTE public.create_draft (42501)');
  end;
end $$;

reset role;
rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
