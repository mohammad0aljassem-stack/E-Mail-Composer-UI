-- ============================================================================
-- Phase 3A contract hardening tests — sender authority, strict idempotency,
-- durable claimable mailbox-sync requests.
--
-- Plain-SQL tests (no pgTAP). Run with: psql -v ON_ERROR_STOP=1 -f <this>
-- against a database with baseline + Phase 2 chain + Phase 3 foundation + the
-- 20260714100000 hardening migration applied. Any uncaught exception makes psql
-- exit non-zero (the runner reports FAIL). Each passing assertion emits:
-- NOTICE ok - <message>.
--
-- Proven here (the three corrected defects):
--   1. SENDER AUTHORITY — create_send_intent derives the Message-ID domain from
--      the MAILBOX address and rejects (22023) any p_sender that does not match
--      the mailbox address after trim+lowercase, writing NO intent/attempt/audit
--      row on rejection; a normalized (spaced/upper-cased) matching sender
--      succeeds and is stored normalized.
--   2. STRICT IDEMPOTENCY — a same-key replay with a byte-identical payload
--      returns the same intent; a same-key call with ANY changed field raises
--      P0409; a same-key call from a NON-member workspace raises a uniform P0002
--      (never P0409 — no existence leak).
--   3. DURABLE SYNC REQUEST — request_mailbox_sync writes a durable, claimable
--      transport.sync_requests row + a content-free audit event; a duplicate
--      request dedups to the SAME open row; a non-member gets a uniform P0002;
--      anon/authenticated have ZERO table privilege and transport_worker has
--      exactly SELECT+UPDATE.
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

-- ---------------------------------------------------------------------------
-- Seed users/workspaces/members (superuser; idempotent — persists across files).
--   A = 1111… member of W1 = aaaa…    C = 3333… member of W2 = bbbb…
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

-- M1 in W1 (enabled), M2 in W2 (enabled).
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'ops@w1.example.com', true, '11111111-1111-1111-1111-111111111111'),
  ('cccccccc-cccc-cccc-cccc-ccccccccccc2', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'ops@w2.example.com', true, '33333333-3333-3333-3333-333333333333')
on conflict (id) do nothing;

-- A draft in W1 (via the Phase 2 RPC, as member A) to feed create_send_intent.
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare d public.drafts;
begin
  d := public.create_draft('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'hardening', public.test_doc('body'));
  insert into t_ctx values ('draft', d.id::text), ('draft_rev', d.revision::text);
end $$;
reset role;

-- =====================================================================
-- 1. SENDER AUTHORITY (member A)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;

-- 1a. A matching sender that only differs by surrounding space + letter case is
--     accepted (documented normalization = trim + lowercase); the stored sender
--     is the normalized authoritative address; the Message-ID domain comes from
--     the MAILBOX address.
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
begin
  i := public.create_send_intent(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cccccccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev,
    '  OPS@W1.Example.com  ',                    -- padded + mixed case; matches after normalize
    '{"to":["dest@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'hardening', null, null, '[]'::jsonb,
    null, null, 2, 'sa-pos-1');
  perform public.test_assert(i.id is not null, 'sender authority: normalized matching sender succeeds');
  perform public.test_assert(i.sender = 'ops@w1.example.com',
    'sender authority: the stored sender is the normalized authoritative address');
  perform public.test_assert(i.message_id ~ '^<[^<>@]+@w1\.example\.com>$',
    'sender authority: message_id domain is derived from the MAILBOX address');
end $$;

-- 1b. A mismatched sender is rejected (22023) and writes NO intent/attempt/audit row.
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  n_i_before int; n_a_before int; n_au_before int;
  n_i_after int;  n_a_after int;  n_au_after int;
  caught boolean := false;
begin
  select count(*) into n_i_before from public.send_intents;
  select count(*) into n_a_before from public.send_attempts;
  select count(*) into n_au_before from public.transport_audit where event_type = 'send_intent_created';
  begin
    perform public.create_send_intent(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'cccccccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev,
      'evil@attacker.example',                    -- NOT the mailbox address
      '{"to":["dest@example.com"]}'::jsonb,
      'hardening', null, null, '[]'::jsonb,
      null, null, 2, 'sa-neg-1');
  exception when sqlstate '22023' then
    caught := true;
  end;
  perform public.test_assert(caught, 'sender authority: mismatched sender rejected with 22023');
  select count(*) into n_i_after from public.send_intents;
  select count(*) into n_a_after from public.send_attempts;
  select count(*) into n_au_after from public.transport_audit where event_type = 'send_intent_created';
  perform public.test_assert(n_i_after = n_i_before, 'sender authority: no send_intent row written on rejection');
  perform public.test_assert(n_a_after = n_a_before, 'sender authority: no send_attempt row written on rejection');
  perform public.test_assert(n_au_after = n_au_before, 'sender authority: no audit row written on rejection');
end $$;

-- =====================================================================
-- 2. STRICT IDEMPOTENCY (member A)
-- =====================================================================

-- 2a. Establish the baseline intent under key 'idem-strict'.
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
begin
  i := public.create_send_intent(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cccccccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w1.example.com',
    '{"to":["a@b.com"],"cc":[],"bcc":[]}'::jsonb, 'hardening',
    repeat('a', 64), repeat('b', 64), '[{"name":"f"}]'::jsonb,
    '99999999-9999-9999-9999-999999999991', '99999999-9999-9999-9999-999999999992',
    2, 'idem-strict');
  insert into t_ctx values ('strict', i.id::text);
end $$;

-- 2b. Same key + byte-identical payload => the SAME intent (idempotent replay).
do $$
declare
  i public.send_intents;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  v_strict uuid := (select val from t_ctx where key = 'strict')::uuid;
  n int;
begin
  i := public.create_send_intent(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cccccccc-cccc-cccc-cccc-ccccccccccc1',
    v_draft, v_rev, 'ops@w1.example.com',
    '{"to":["a@b.com"],"cc":[],"bcc":[]}'::jsonb, 'hardening',
    repeat('a', 64), repeat('b', 64), '[{"name":"f"}]'::jsonb,
    '99999999-9999-9999-9999-999999999991', '99999999-9999-9999-9999-999999999992',
    2, 'idem-strict');
  perform public.test_assert(i.id = v_strict, 'strict idempotency: identical replay returns the same intent');
  select count(*) into n from public.send_intents where idempotency_key = 'idem-strict';
  perform public.test_assert(n = 1, 'strict idempotency: identical replay creates no duplicate');
end $$;

-- 2c. Same key + EACH kind of changed field => P0409. A generic helper runs one
--     divergent call and asserts the expected code. Each row below flips exactly
--     one field away from the baseline in 2a (subject 'hardening', contract 2);
--     every non-target field MATCHES the baseline so exactly one axis diverges
--     and the divergence is proven to be what raises the conflict.
--
--     Under the Slice-1 contract, contract_version is server-pinned to exactly 2
--     (any other value is a fail-closed 22023 at the gate, BEFORE the idempotency
--     lookup). A "changed contract_version" fingerprint divergence is therefore
--     no longer expressible; the corresponding case now proves the meaningful
--     replacement — a non-2 contract_version is REJECTED at the gate (22023),
--     never reaching the idempotency path. Each row declares its expected code.
do $$
declare
  r record;
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  got text;
begin
  for r in
    select label,
           p_ws, p_mb, p_dr, p_sender, p_rcpt, p_subj, p_html, p_text, p_manifest, p_tmpl, p_sig, p_contract, expected
    from (values
      ('changed subject',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening CHANGED',
        repeat('a',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-999999999992', 2, 'P0409'),
      ('changed recipients',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["z@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('a',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-999999999992', 2, 'P0409'),
      ('changed draft_revision',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev + 1,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('a',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-999999999992', 2, 'P0409'),
      ('changed html_hash',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('c',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-999999999992', 2, 'P0409'),
      ('changed attachment_manifest',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('a',64), repeat('b',64), '[]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-999999999992', 2, 'P0409'),
      ('changed template_version_id',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('a',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-99999999999a','99999999-9999-9999-9999-999999999992', 2, 'P0409'),
      ('changed signature_id',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('a',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-99999999999b', 2, 'P0409'),
      ('non-2 contract_version rejected at the gate',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-ccccccccccc1', v_rev,
        'ops@w1.example.com', '{"to":["a@b.com"],"cc":[],"bcc":[]}', 'hardening',
        repeat('a',64), repeat('b',64), '[{"name":"f"}]',
        '99999999-9999-9999-9999-999999999991','99999999-9999-9999-9999-999999999992', 1, '22023')
    ) t(label, p_ws, p_mb, p_dr, p_sender, p_rcpt, p_subj, p_html, p_text, p_manifest, p_tmpl, p_sig, p_contract, expected)
  loop
    got := null;
    begin
      perform public.create_send_intent(
        r.p_ws::uuid, r.p_mb::uuid, v_draft, r.p_dr::bigint, r.p_sender,
        r.p_rcpt::jsonb, r.p_subj, nullif(r.p_html,''), nullif(r.p_text,''),
        r.p_manifest::jsonb, r.p_tmpl::uuid, r.p_sig::uuid, r.p_contract::integer,
        'idem-strict');
      got := 'no-error';
    exception
      when sqlstate 'P0409' then got := 'P0409';
      when sqlstate '22023' then got := '22023';
      when others then got := sqlstate;
    end;
    perform public.test_assert(got = r.expected,
      format('strict idempotency: %s under the same key raises %s (got %s)', r.label, r.expected, got));
  end loop;
end $$;

-- 2d. A changed SENDER under the same key also diverges the fingerprint => P0409
--     (proves the authoritative sender is part of the fingerprint; and it is
--     caught BEFORE the sender-authority check, so it is P0409, not 22023).
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  v_rev bigint := (select val from t_ctx where key = 'draft_rev')::bigint;
  got text := null;
begin
  begin
    perform public.create_send_intent(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'cccccccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, v_rev, 'other@w1.example.com',
      '{"to":["a@b.com"],"cc":[],"bcc":[]}'::jsonb, 'hardening',
      repeat('a', 64), repeat('b', 64), '[{"name":"f"}]'::jsonb,
      '99999999-9999-9999-9999-999999999991', '99999999-9999-9999-9999-999999999992',
      2, 'idem-strict');
    got := 'no-error';
  exception
    when sqlstate 'P0409' then got := 'P0409';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0409',
    format('strict idempotency: a changed sender under the same key raises P0409 (got %s)', got));
end $$;

reset role;

-- 2e. Same key from a NON-member workspace => uniform P0002 (never P0409). The
--     key 'idem-strict' exists in W1; member C of W2 must not learn that (no
--     existence/P0409 leak), regardless of payload divergence.
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_draft uuid := (select val from t_ctx where key = 'draft')::uuid;
  got text := null;
begin
  begin
    perform public.create_send_intent(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',     -- claims W1 (C is not a member)
      'cccccccc-cccc-cccc-cccc-ccccccccccc1',
      v_draft, 1, 'ops@w1.example.com',
      '{"to":["different@b.com"]}'::jsonb, 'hardening', null, null, '[]'::jsonb,
      null, null, 2, 'idem-strict');
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('strict idempotency: non-member reusing an existing key gets P0002, not P0409 (got %s)', got));
end $$;
reset role;

-- =====================================================================
-- 3. DURABLE, CLAIMABLE MAILBOX-SYNC REQUEST
-- =====================================================================

-- 3a. Member A: request_mailbox_sync writes a durable row + a content-free audit
--     event and returns the durable request id/status.
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v jsonb; n int;
begin
  v := public.request_mailbox_sync('cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  perform public.test_assert(v ->> 'status' = 'pending', 'durable sync: RPC returns durable status=pending');
  perform public.test_assert((v ->> 'sync_request_id') is not null, 'durable sync: RPC returns a durable sync_request_id');
  insert into t_ctx values ('sync1', v ->> 'sync_request_id');
  select count(*) into n from public.transport_audit
    where mailbox_id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1' and event_type = 'mailbox_sync_requested';
  perform public.test_assert(n = 1, 'durable sync: a content-free audit event is appended');
end $$;

-- 3b. A duplicate request dedups to the SAME open row (returns the existing one).
do $$
declare v jsonb; v_first uuid := (select val from t_ctx where key = 'sync1')::uuid;
begin
  v := public.request_mailbox_sync('cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  perform public.test_assert((v ->> 'sync_request_id')::uuid = v_first,
    'durable sync: a duplicate request dedups to the same open row');
end $$;
reset role;

-- 3c. Superuser inspection of the PRIVATE durable row (browser roles cannot).
do $$
declare n int;
begin
  select count(*) into n from transport.sync_requests
    where mailbox_id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1';
  perform public.test_assert(n = 1, 'durable sync: exactly one durable row exists after the duplicate (dedup, not two rows)');
  select count(*) into n from transport.sync_requests
    where mailbox_id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1'
      and status in ('pending','claimed');
  perform public.test_assert(n = 1, 'durable sync: exactly one OPEN request per mailbox (dedup index holds)');
  select count(*) into n from transport.sync_requests
    where mailbox_id = 'cccccccc-cccc-cccc-cccc-ccccccccccc1'
      and status = 'pending' and folder is null and requested_by = '11111111-1111-1111-1111-111111111111';
  perform public.test_assert(n = 1, 'durable sync: the row is a pending whole-mailbox request stamped with the requester');
end $$;

-- 3d. Non-member (C of W2) cannot request a sync of a W1 mailbox => uniform P0002.
select set_config('request.jwt.claims',
  '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
do $$
declare got text := null;
begin
  begin
    perform public.request_mailbox_sync(
      'cccccccc-cccc-cccc-cccc-ccccccccccc1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    got := 'no-error';
  exception
    when sqlstate 'P0002' then got := 'P0002';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = 'P0002',
    format('durable sync: cross-workspace non-member gets a uniform P0002 (got %s)', got));
end $$;
reset role;

-- 3e. transport.sync_requests privilege matrix: anon/authenticated ZERO on all
--     four privileges; transport_worker EXACTLY SELECT+UPDATE; service_role ALL.
do $$
declare r record; expected boolean; actual boolean;
begin
  for r in
    select roles.role, privs.priv
    from (values ('anon'),('authenticated'),('service_role'),('transport_worker')) roles(role)
    cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE')) privs(priv)
  loop
    actual := has_table_privilege(r.role, 'transport.sync_requests'::regclass, r.priv);
    expected := case
      when r.role = 'service_role' then true
      when r.role in ('anon','authenticated') then false
      else r.priv in ('SELECT','UPDATE')          -- transport_worker: claim only
    end;
    perform public.test_assert(actual = expected,
      format('durable sync privilege: %s %s on transport.sync_requests = %s', r.role, r.priv, expected));
  end loop;
end $$;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
