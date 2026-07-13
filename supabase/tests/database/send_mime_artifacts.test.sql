-- ============================================================================
-- Phase 3B database tests — private exact MIME artifacts
--
-- Plain-SQL tests (no pgTAP). Run with: psql -v ON_ERROR_STOP=1 -f <this>
-- against a database with the full migration chain (through 20260717100000)
-- applied. Any uncaught exception makes psql exit non-zero. Each passing
-- assertion emits: NOTICE ok - <message>.
--
-- Proven here:
--   1. WORKER WRITE PATH — transport_worker inserts a valid artifact whose
--      sha256/size are verified against the exact raw bytes and whose
--      attempt/intent/workspace/message_id chain must be consistent (each
--      mismatch: 23514; wrong size / oversize: 23514 check violations;
--      duplicate per attempt: 23505 — the worker repository's idempotent
--      handling of an identical replay is its INSERT ... ON CONFLICT path).
--   2. BROWSER DENIAL — anon/authenticated cannot SELECT/INSERT/UPDATE/DELETE
--      the artifact table at all (42501; no schema USAGE, no table privilege).
--   3. IMMUTABILITY + RETENTION — any UPDATE other than the single clearing
--      transition is 23514; clearing is refused (23514) while the attempt is
--      smtp_in_progress / needs_human_review / sent_copy_pending and succeeds
--      once the attempt is completed, preserving mime_sha256/size_bytes/
--      message_id; the worker holds NO DELETE.
--   4. CONTENT HYGIENE — public.transport_audit has no bytea column and this
--      suite's raw MIME marker never appears in any audit row.
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
-- Fixture (superuser): Uma = member of WS-A; WS-B exists only as a foreign
-- workspace for the mismatch test. Two intents (each with its seeded
-- 'confirmed' attempt) are created via the real RPCs.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('77771111-1111-1111-1111-111111111111', 'uma@example.com', '{"full_name":"Uma"}');
insert into public.workspaces (id, name) values
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Artifact Workspace A'),
  ('7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Artifact Workspace B');
insert into public.workspace_members (workspace_id, user_id, role) values
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77771111-1111-1111-1111-111111111111', 'owner');
insert into public.mailboxes (id, workspace_id, email_address, enabled, created_by) values
  ('7777cccc-cccc-cccc-cccc-ccccccccccc1', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'ops@w7.example.com', true, '77771111-1111-1111-1111-111111111111');

select set_config('request.jwt.claims',
  '{"sub":"77771111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  d1 public.drafts; d2 public.drafts;
  i1 public.send_intents; i2 public.send_intents;
  a1 uuid; a2 uuid;
begin
  d1 := public.create_draft('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'mime one', public.test_doc('body one'));
  i1 := public.create_send_intent(
    '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '7777cccc-cccc-cccc-cccc-ccccccccccc1',
    d1.id, d1.revision, 'ops@w7.example.com',
    '{"to":["one@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'mime one', null, null, '[]'::jsonb, null, null, 1, 'mime-idem-1');
  d2 := public.create_draft('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'mime two', public.test_doc('body two'));
  i2 := public.create_send_intent(
    '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '7777cccc-cccc-cccc-cccc-ccccccccccc1',
    d2.id, d2.revision, 'ops@w7.example.com',
    '{"to":["two@example.com"],"cc":[],"bcc":[]}'::jsonb,
    'mime two', null, null, '[]'::jsonb, null, null, 1, 'mime-idem-2');
  select id into a1 from public.send_attempts where send_intent_id = i1.id;
  select id into a2 from public.send_attempts where send_intent_id = i2.id;
  insert into t_ctx values
    ('intent1', i1.id::text), ('attempt1', a1::text), ('msgid1', i1.message_id),
    ('intent2', i2.id::text), ('attempt2', a2::text), ('msgid2', i2.message_id);
end $$;
reset role;

-- The exact raw MIME payload used throughout (the marker string below also
-- powers the content-hygiene assertion at the end).
do $$
declare v_raw bytea := convert_to(
  'MIME-Version: 1.0' || chr(13) || chr(10) ||
  'Subject: mime one' || chr(13) || chr(10) ||
  'X-Test-Marker: PHASE3B-RAW-MIME-MARKER' || chr(13) || chr(10) ||
  chr(13) || chr(10) || 'body one', 'UTF8');
begin
  insert into t_ctx values
    ('raw_hex', encode(v_raw, 'hex')),
    ('raw_sha', encode(sha256(v_raw), 'hex')),
    ('raw_len', octet_length(v_raw)::text);
end $$;

-- =====================================================================
-- 1. WORKER WRITE PATH (set role transport_worker; no test-only grant)
-- =====================================================================
set local role transport_worker;

-- 1a. A fully consistent artifact inserts and reads back exactly.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a1 uuid := (select val from t_ctx where key = 'attempt1')::uuid;
  v_i1 uuid := (select val from t_ctx where key = 'intent1')::uuid;
  v_msg text := (select val from t_ctx where key = 'msgid1');
  v_id uuid;
  r transport.send_mime_artifacts;
begin
  insert into transport.send_mime_artifacts
    (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
  values
    (v_a1, v_i1, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw)
  returning id into v_id;
  perform public.test_assert(v_id is not null, 'worker: a valid exact-MIME artifact inserts');
  select * into r from transport.send_mime_artifacts where id = v_id;
  perform public.test_assert(r.raw_mime = v_raw and r.mime_sha256 = v_sha and r.size_bytes = v_len,
    'worker: the stored artifact carries the exact bytes, sha256 and size');
  perform public.test_assert(r.cleared_at is null,
    'worker: a fresh artifact is not cleared');
  insert into t_ctx values ('artifact1', v_id::text);
end $$;

-- 1b. Mismatched workspace (intent lives in WS-A, row claims WS-B) => 23514.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i2 uuid := (select val from t_ctx where key = 'intent2')::uuid;
  v_msg2 text := (select val from t_ctx where key = 'msgid2');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a2, v_i2, '7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_msg2, v_sha, v_len, v_raw);
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('worker: a workspace mismatch is rejected with 23514 (got %s)', got));
end $$;

-- 1c. Mismatched intent (attempt2 claimed against intent1) => 23514.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i1 uuid := (select val from t_ctx where key = 'intent1')::uuid;
  v_msg text := (select val from t_ctx where key = 'msgid1');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a2, v_i1, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('worker: an attempt belonging to another intent is rejected with 23514 (got %s)', got));
end $$;

-- 1d. Mismatched message_id => 23514.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i2 uuid := (select val from t_ctx where key = 'intent2')::uuid;
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a2, v_i2, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '<forged@w7.example.com>', v_sha, v_len, v_raw);
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('worker: a message_id differing from the intent''s is rejected with 23514 (got %s)', got));
end $$;

-- 1e. Wrong size (bytes present but size_bytes off by one) => 23514 check.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i2 uuid := (select val from t_ctx where key = 'intent2')::uuid;
  v_msg2 text := (select val from t_ctx where key = 'msgid2');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a2, v_i2, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg2, v_sha, v_len + 1, v_raw);
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('worker: a size_bytes not matching octet_length(raw_mime) is rejected with 23514 (got %s)', got));
end $$;

-- 1f. Wrong hash (valid hex, wrong digest) => 23514.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i2 uuid := (select val from t_ctx where key = 'intent2')::uuid;
  v_msg2 text := (select val from t_ctx where key = 'msgid2');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a2, v_i2, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg2, repeat('0', 64), v_len, v_raw);
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('worker: a mime_sha256 not matching sha256(raw_mime) is rejected with 23514 (got %s)', got));
end $$;

-- 1g. Oversized payload (26214401 bytes, hash and size otherwise exact) =>
--     23514 (the 25 MiB size_bytes bound).
do $$
declare
  v_big bytea := convert_to(repeat('x', 26214401), 'UTF8');
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i2 uuid := (select val from t_ctx where key = 'intent2')::uuid;
  v_msg2 text := (select val from t_ctx where key = 'msgid2');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a2, v_i2, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg2,
       encode(sha256(v_big), 'hex'), octet_length(v_big), v_big);
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('worker: a payload over 26214400 bytes is rejected with 23514 (got %s)', got));
end $$;

-- 1h. A second artifact for the SAME attempt => unique violation 23505. The
--     worker repository handles an identical idempotent replay via its
--     INSERT ... ON CONFLICT (send_attempt_id) DO NOTHING path; at the schema
--     level a duplicate is always a conflict.
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_a1 uuid := (select val from t_ctx where key = 'attempt1')::uuid;
  v_i1 uuid := (select val from t_ctx where key = 'intent1')::uuid;
  v_msg text := (select val from t_ctx where key = 'msgid1');
  got text := null;
begin
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values
      (v_a1, v_i1, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg, v_sha, v_len, v_raw);
    got := 'no-error';
  exception
    when unique_violation then got := '23505';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23505',
    format('worker: a duplicate artifact for the same attempt is a unique violation 23505 (got %s)', got));
end $$;

reset role;

-- =====================================================================
-- 2. BROWSER DENIAL — anon/authenticated have ZERO reach (42501)
-- =====================================================================
select set_config('request.jwt.claims',
  '{"sub":"77771111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
begin
  begin
    perform 1 from transport.send_mime_artifacts limit 1;
    raise exception 'authenticated SELECTed send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot SELECT transport.send_mime_artifacts (42501)');
  end;
  begin
    insert into transport.send_mime_artifacts
      (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
    values (v_art, v_art, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '<x@y>', repeat('0', 64), 1, '\x00');
    raise exception 'authenticated INSERTed send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot INSERT transport.send_mime_artifacts (42501)');
  end;
  begin
    update transport.send_mime_artifacts set cleared_at = now() where id = v_art;
    raise exception 'authenticated UPDATEd send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot UPDATE transport.send_mime_artifacts (42501)');
  end;
  begin
    delete from transport.send_mime_artifacts where id = v_art;
    raise exception 'authenticated DELETEd send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'browser: authenticated cannot DELETE transport.send_mime_artifacts (42501)');
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
    perform public.test_assert(true, 'browser: anon cannot SELECT transport.send_mime_artifacts (42501)');
  end;
end $$;
reset role;

-- Catalog matrix: worker exactly SELECT+INSERT+UPDATE; browser roles nothing;
-- service_role all.
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
      else r.priv in ('SELECT','INSERT','UPDATE')   -- transport_worker: never DELETE
    end;
    perform public.test_assert(actual = expected,
      format('artifact privilege: %s %s on transport.send_mime_artifacts = %s', r.role, r.priv, expected));
  end loop;
end $$;

-- =====================================================================
-- 3. IMMUTABILITY + RETENTION (worker drives the real state machine)
-- =====================================================================
set local role transport_worker;

-- 3a. Any non-clearing UPDATE is rejected: divergent raw_mime replacement
--     (even with a matching hash/size for the NEW bytes) and metadata edits.
do $$
declare
  v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
  v_new bytea := convert_to('tampered replacement bytes', 'UTF8');
  got text := null;
begin
  begin
    update transport.send_mime_artifacts
      set raw_mime = v_new,
          mime_sha256 = encode(sha256(v_new), 'hex'),
          size_bytes = octet_length(v_new)
      where id = v_art;
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('immutability: replacing the raw bytes via UPDATE is rejected with 23514 (got %s)', got));
  got := null;
  begin
    update transport.send_mime_artifacts set message_id = '<other@w7.example.com>' where id = v_art;
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('immutability: editing artifact metadata via UPDATE is rejected with 23514 (got %s)', got));
end $$;

-- 3b. Clearing is refused while the attempt is smtp_in_progress (23514).
do $$
declare
  v_a1 uuid := (select val from t_ctx where key = 'attempt1')::uuid;
  v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
  got text := null;
begin
  update public.send_attempts set state = 'queued',           version = version + 1 where id = v_a1;
  update public.send_attempts set state = 'claimed',          version = version + 1 where id = v_a1;
  update public.send_attempts set state = 'smtp_in_progress', version = version + 1 where id = v_a1;
  begin
    update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_art;
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('retention: clearing while the attempt is smtp_in_progress is rejected with 23514 (got %s)', got));
end $$;

-- 3c. Clearing is refused while the attempt is sent_copy_pending (23514).
do $$
declare
  v_a1 uuid := (select val from t_ctx where key = 'attempt1')::uuid;
  v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
  got text := null;
begin
  update public.send_attempts set state = 'smtp_accepted',     version = version + 1 where id = v_a1;
  update public.send_attempts set state = 'sent_copy_pending', version = version + 1 where id = v_a1;
  begin
    update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_art;
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('retention: clearing while the attempt is sent_copy_pending is rejected with 23514 (got %s)', got));
end $$;

-- 3d. Clearing is refused while the attempt is needs_human_review (23514):
--     artifact2 on attempt2 (which is driven to needs_human_review).
do $$
declare
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  v_a2 uuid := (select val from t_ctx where key = 'attempt2')::uuid;
  v_i2 uuid := (select val from t_ctx where key = 'intent2')::uuid;
  v_msg2 text := (select val from t_ctx where key = 'msgid2');
  v_id uuid;
  got text := null;
begin
  insert into transport.send_mime_artifacts
    (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
  values
    (v_a2, v_i2, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_msg2,
     encode(sha256(v_raw), 'hex'), octet_length(v_raw), v_raw)
  returning id into v_id;
  update public.send_attempts set state = 'queued',             version = version + 1 where id = v_a2;
  update public.send_attempts set state = 'claimed',            version = version + 1 where id = v_a2;
  update public.send_attempts set state = 'needs_human_review', version = version + 1 where id = v_a2;
  begin
    update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_id;
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('retention: clearing while the attempt is needs_human_review is rejected with 23514 (got %s)', got));
end $$;

-- 3e. Clearing after 'completed' succeeds and PRESERVES the proof metadata.
do $$
declare
  v_a1 uuid := (select val from t_ctx where key = 'attempt1')::uuid;
  v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
  v_sha text := (select val from t_ctx where key = 'raw_sha');
  v_len bigint := (select val from t_ctx where key = 'raw_len')::bigint;
  v_msg text := (select val from t_ctx where key = 'msgid1');
  r transport.send_mime_artifacts;
begin
  update public.send_attempts set state = 'completed', version = version + 1 where id = v_a1;
  update transport.send_mime_artifacts set raw_mime = null, cleared_at = now() where id = v_art;
  select * into r from transport.send_mime_artifacts where id = v_art;
  perform public.test_assert(r.raw_mime is null and r.cleared_at is not null,
    'retention: clearing after completed succeeds (raw gone, cleared_at stamped)');
  perform public.test_assert(
    r.mime_sha256 = v_sha and r.size_bytes = v_len and r.message_id = v_msg,
    'retention: clearing preserves mime_sha256, size_bytes and message_id');
end $$;

-- 3f. A cleared artifact stays frozen: re-clearing / re-attaching bytes is 23514.
do $$
declare
  v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
  v_raw bytea := decode((select val from t_ctx where key = 'raw_hex'), 'hex');
  got text := null;
begin
  begin
    update transport.send_mime_artifacts set raw_mime = v_raw, cleared_at = null where id = v_art;
    got := 'no-error';
  exception
    when sqlstate '23514' then got := '23514';
    when others then got := sqlstate;
  end;
  perform public.test_assert(got = '23514',
    format('retention: re-attaching bytes to a cleared artifact is rejected with 23514 (got %s)', got));
end $$;

-- 3g. The worker holds NO DELETE (42501), so evidence cannot be destroyed.
do $$
declare v_art uuid := (select val from t_ctx where key = 'artifact1')::uuid;
begin
  begin
    delete from transport.send_mime_artifacts where id = v_art;
    raise exception 'worker DELETEd send_mime_artifacts' using errcode = 'ASSRT';
  exception when insufficient_privilege then
    perform public.test_assert(true, 'retention: transport_worker cannot DELETE artifacts (42501)');
  end;
end $$;

reset role;

-- =====================================================================
-- 4. CONTENT HYGIENE — the audit trail can never carry raw MIME
-- =====================================================================
do $$
declare n int;
begin
  -- Structural: transport_audit has no bytea column at all.
  select count(*) into n
  from pg_attribute
  where attrelid = 'public.transport_audit'::regclass
    and attnum > 0 and not attisdropped
    and atttypid = 'bytea'::regtype;
  perform public.test_assert(n = 0,
    'hygiene: public.transport_audit has no bytea column (raw MIME is structurally impossible)');
  -- Behavioral: nothing this suite did leaked the raw marker into any audit row.
  select count(*) into n
  from public.transport_audit
  where detail::text like '%PHASE3B-RAW-MIME-MARKER%'
     or coalesce(message_id, '') like '%PHASE3B-RAW-MIME-MARKER%';
  perform public.test_assert(n = 0,
    'hygiene: no transport_audit row contains this suite''s raw MIME marker');
end $$;

rollback;

reset role;
drop function if exists public.test_assert(boolean, text);
drop function if exists public.test_doc(text);
