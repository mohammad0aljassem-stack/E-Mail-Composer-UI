-- ============================================================================
-- Phase 3B — Private exact MIME artifacts (worker-owned send evidence)
-- Migration: 20260717100000_send_mime_artifacts.sql
--
-- Applied AFTER the existing chain (…20260715100000_worker_transition_grant ->
-- 20260716100000_confirmed_send_snapshots -> THIS). Strictly ADDITIVE: it only
-- CREATEs one new PRIVATE table in the transport schema plus its two integrity
-- trigger functions, and asserts grants. It never alters or drops any prior
-- object. Idempotency guards (create table/index if not exists / create or
-- replace / revoke-then-grant) make a re-run a no-op.
--
-- WHAT THIS TABLE IS:
--   transport.send_mime_artifacts stores, per send_attempt, the EXACT raw MIME
--   bytes the worker handed to SMTP, bound by sha256 + size, so a delivered
--   message can be proven byte-for-byte and appended verbatim to the Sent
--   folder. It lives in the PRIVATE transport schema: anon/authenticated have
--   ZERO access (no schema USAGE, no table privilege) — raw message content can
--   NEVER reach the browser.
--
-- CONTRACT (enforced below):
--   * INSERT (worker-only) requires raw_mime NOT NULL whose sha256 matches
--     mime_sha256 and whose byte length matches size_bytes; the attempt must
--     belong to the claimed intent, and the intent's workspace + message_id
--     must match the row (all 23514 on violation). One artifact per attempt.
--   * IMMUTABILITY: the ONLY legal UPDATE is the retention-clearing transition
--     (raw_mime NOT NULL -> NULL together with cleared_at NULL -> NOT NULL,
--     every other column byte-identical), and ONLY once the attempt is in a
--     terminal-for-delivery state ('completed', 'failed_before_delivery',
--     'cancelled'). Everything else is 23514. mime_sha256/size_bytes/message_id
--     survive clearing, so the proof outlives the bytes.
--   * 25 MiB bound (26214400 bytes) on size_bytes; raw byte length must equal
--     size_bytes while present.
--   * transport_worker gets exactly SELECT, INSERT, UPDATE — NO DELETE for any
--     role except service_role's operational ownership.
--
-- Error-code conventions (mirror Phase 3A):
--   23514 integrity violation (hash/size/parent mismatch, illegal update)
--   23505 duplicate artifact for the same attempt (unique violation; the worker
--         repository's idempotent path is INSERT ... ON CONFLICT DO NOTHING)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The table (PRIVATE — no anon/authenticated access whatsoever)
-- ---------------------------------------------------------------------------
create table if not exists transport.send_mime_artifacts (
  id uuid primary key default gen_random_uuid(),
  send_attempt_id uuid not null references public.send_attempts (id) on delete restrict,
  send_intent_id uuid not null references public.send_intents (id) on delete restrict,
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  message_id text not null
    constraint send_mime_artifacts_message_id_max_len check (char_length(message_id) <= 998),
  mime_sha256 text not null
    constraint send_mime_artifacts_sha_hex check (mime_sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes bigint not null
    constraint send_mime_artifacts_size_positive check (size_bytes > 0),
  raw_mime bytea,
  created_at timestamptz not null default now(),
  cleared_at timestamptz,
  constraint send_mime_artifacts_one_per_attempt unique (send_attempt_id),
  -- 25 MiB hard bound on the exact MIME payload.
  constraint send_mime_artifacts_size_bound check (size_bytes <= 26214400),
  -- While the bytes are present they must be EXACTLY size_bytes long.
  constraint send_mime_artifacts_raw_matches_size check (raw_mime is null or octet_length(raw_mime) = size_bytes),
  -- Retention truth: cleared_at set => bytes gone; bytes present => not cleared.
  constraint send_mime_artifacts_cleared_consistent check (cleared_at is null or raw_mime is null)
);
comment on table transport.send_mime_artifacts is
  'Phase 3B (PRIVATE): the EXACT raw MIME bytes per send_attempt, bound by sha256 + size and verified against the attempt/intent chain on insert. One artifact per attempt. The only legal UPDATE is the retention-clearing transition (raw_mime -> NULL + cleared_at stamped, metadata byte-identical) once the attempt is completed/failed_before_delivery/cancelled; mime_sha256/size_bytes/message_id survive clearing. Max 26214400 bytes (25 MiB). Unreachable by the browser; worker: SELECT/INSERT/UPDATE, never DELETE.';
comment on column transport.send_mime_artifacts.mime_sha256 is
  'sha256 (lowercase hex) over raw_mime, verified by the BEFORE INSERT trigger; survives clearing as the durable proof of the exact bytes sent.';
comment on column transport.send_mime_artifacts.raw_mime is
  'The exact MIME bytes handed to SMTP. NOT NULL on insert (trigger-enforced); set to NULL only by the retention-clearing transition after the attempt reaches a terminal-for-delivery state.';
comment on column transport.send_mime_artifacts.cleared_at is
  'When the raw bytes were cleared for retention. NULL while raw_mime is present; stamped exactly when raw_mime is nulled (the only legal UPDATE).';

create index if not exists idx_send_mime_artifacts_send_intent_id on transport.send_mime_artifacts (send_intent_id);
create index if not exists idx_send_mime_artifacts_workspace_id on transport.send_mime_artifacts (workspace_id);

-- ---------------------------------------------------------------------------
-- 2. Integrity trigger functions (SECURITY INVOKER, empty search_path — the
--    worker owns the insert and holds SELECT on the parent tables it verifies)
-- ---------------------------------------------------------------------------

-- 2.1 BEFORE INSERT: exact-bytes binding + parent-chain consistency.
create or replace function transport.mime_artifacts_before_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_attempt public.send_attempts;
  v_intent public.send_intents;
begin
  -- (1) The bytes must be present and hash to exactly the declared sha256.
  if new.raw_mime is null then
    raise exception 'send_mime_artifacts.raw_mime must be NOT NULL on insert'
      using errcode = '23514';
  end if;
  if encode(sha256(new.raw_mime), 'hex') <> new.mime_sha256 then
    raise exception 'send_mime_artifacts.mime_sha256 does not match sha256(raw_mime)'
      using errcode = '23514';
  end if;
  -- (2) The attempt must exist and belong to the claimed intent.
  select * into v_attempt from public.send_attempts a where a.id = new.send_attempt_id;
  if not found or v_attempt.send_intent_id is distinct from new.send_intent_id then
    raise exception 'send_mime_artifacts.send_attempt_id must reference an attempt of send_intent_id'
      using errcode = '23514';
  end if;
  -- (3) The intent's workspace and Message-ID must match the artifact row.
  select * into v_intent from public.send_intents i where i.id = new.send_intent_id;
  if not found
     or v_intent.workspace_id is distinct from new.workspace_id
     or v_intent.message_id is distinct from new.message_id then
    raise exception 'send_mime_artifacts workspace_id/message_id must match the send_intent'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function transport.mime_artifacts_before_insert() is
  'Phase 3B integrity: an inserted MIME artifact must carry the exact bytes (sha256(raw_mime) = mime_sha256, raw_mime NOT NULL) and be consistent with its parent chain (attempt belongs to the intent; intent''s workspace_id + message_id match the row). 23514 on any violation.';

-- 2.2 BEFORE UPDATE: only the retention-clearing transition, only after the
--     attempt reached a terminal-for-delivery state.
create or replace function transport.mime_artifacts_before_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_state text;
begin
  -- The ONE legal shape: raw bytes go away, cleared_at gets stamped, and every
  -- other column is byte-identical.
  if not (old.raw_mime is not null and new.raw_mime is null
          and old.cleared_at is null and new.cleared_at is not null
          and new.id = old.id
          and new.send_attempt_id = old.send_attempt_id
          and new.send_intent_id = old.send_intent_id
          and new.workspace_id = old.workspace_id
          and new.message_id = old.message_id
          and new.mime_sha256 = old.mime_sha256
          and new.size_bytes = old.size_bytes
          and new.created_at = old.created_at) then
    raise exception 'send_mime_artifacts rows are immutable except the retention-clearing transition (raw_mime -> NULL + cleared_at stamped, all metadata unchanged)'
      using errcode = '23514';
  end if;
  -- Clearing is allowed only once the attempt is terminal for delivery.
  select a.state into v_state from public.send_attempts a where a.id = old.send_attempt_id;
  if v_state is null or v_state not in ('completed', 'failed_before_delivery', 'cancelled') then
    raise exception 'send_mime_artifacts may be cleared only after the attempt is completed/failed_before_delivery/cancelled (state %)', coalesce(v_state, '<missing>')
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function transport.mime_artifacts_before_update() is
  'Phase 3B integrity: the only legal UPDATE on send_mime_artifacts is the retention-clearing transition (raw_mime NOT NULL -> NULL together with cleared_at NULL -> NOT NULL, every other column unchanged), and only while the attempt state is completed/failed_before_delivery/cancelled. Everything else raises 23514.';

-- Trigger functions are internal machinery: nobody calls them directly.
revoke all on function
  transport.mime_artifacts_before_insert(),
  transport.mime_artifacts_before_update()
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------
create or replace trigger trg_send_mime_artifacts_before_insert
  before insert on transport.send_mime_artifacts
  for each row execute function transport.mime_artifacts_before_insert();
create or replace trigger trg_send_mime_artifacts_before_update
  before update on transport.send_mime_artifacts
  for each row execute function transport.mime_artifacts_before_update();

-- ---------------------------------------------------------------------------
-- 4. Grants (revoke-then-grant; idempotent). anon/authenticated get NOTHING;
--    the worker writes and clears but can NEVER DELETE; service_role keeps its
--    operational ownership. uuid pk => no sequence privilege is needed.
-- ---------------------------------------------------------------------------
revoke all on table transport.send_mime_artifacts from public, anon, authenticated;
grant select, insert, update on table transport.send_mime_artifacts to transport_worker;
grant all on table transport.send_mime_artifacts to service_role;

-- RLS on with NO policies — defence in depth, exactly like mailbox_credentials.
-- The only roles that can reach the schema are BYPASSRLS; even a mistaken future
-- grant would still expose zero rows.
alter table transport.send_mime_artifacts enable row level security;

-- ============================================================================
-- End of migration 20260717100000_send_mime_artifacts.sql
-- ============================================================================
