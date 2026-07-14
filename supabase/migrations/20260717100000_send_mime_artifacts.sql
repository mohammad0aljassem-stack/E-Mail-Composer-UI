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
--   * CREATION is worker-only THROUGH transport.create_or_verify_send_mime_artifact
--     (a SECURITY DEFINER function) — the worker holds NO direct INSERT. A first
--     create requires the attempt to be EXACTLY 'claimed' (so the bytes exist
--     BEFORE SMTP starts), raw_mime NOT NULL whose sha256 matches mime_sha256 and
--     whose byte length matches size_bytes, and the attempt/intent/workspace/
--     message_id chain to be consistent (all 23514). A second call with an
--     artifact already present is the restart/reconciliation VERIFY path: it
--     succeeds only on EXACT identity and NEVER overwrites bytes. The BEFORE
--     INSERT trigger re-enforces the claimed-state gate + the chain for EVERY
--     insert path (including a direct privileged INSERT). One artifact per attempt.
--   * IMMUTABILITY: the ONLY legal UPDATE is the retention-clearing transition
--     (raw_mime NOT NULL -> NULL together with cleared_at NULL -> NOT NULL,
--     every other column byte-identical), and ONLY once the attempt is in a
--     terminal-for-delivery state ('completed', 'failed_before_delivery',
--     'cancelled'). Everything else is 23514. mime_sha256/size_bytes/message_id
--     survive clearing, so the proof outlives the bytes.
--   * 25 MiB bound (26214400 bytes) on size_bytes; raw byte length must equal
--     size_bytes while present.
--   * transport_worker gets exactly SELECT + UPDATE — NEVER INSERT, NEVER DELETE.
--     Only service_role's operational ownership (or a full workspace/draft graph
--     deletion, which the parent CASCADE FKs follow) removes an artifact.
--
-- Error-code conventions (mirror Phase 3A):
--   23514 integrity violation (hash/size/parent mismatch, wrong attempt state,
--         illegal update, or a create/verify divergence — uniform in the function)
--   23505 duplicate artifact for the same attempt (unique violation; the worker's
--         idempotent path is transport.create_or_verify_send_mime_artifact, whose
--         attempt-row FOR UPDATE lock + verify branch make an identical replay a
--         no-op that returns the existing row)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The table (PRIVATE — no anon/authenticated access whatsoever)
-- ---------------------------------------------------------------------------
create table if not exists transport.send_mime_artifacts (
  id uuid primary key default gen_random_uuid(),
  -- ON DELETE CASCADE on both parent references (defect 7): the artifact is
  -- DERIVED evidence that must follow its parent attempt/intent when the whole
  -- workspace/draft graph is deleted (service-role/owner). The worker still
  -- cannot delete artifacts (it holds NO DELETE grant); only a full parent/graph
  -- deletion cascades them away, so a clearing-only worker can never destroy the
  -- proof, yet a legitimate account/workspace teardown removes the entire graph.
  send_attempt_id uuid not null references public.send_attempts (id) on delete cascade,
  send_intent_id uuid not null references public.send_intents (id) on delete cascade,
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
  'Phase 3B (PRIVATE): the EXACT raw MIME bytes per send_attempt, bound by sha256 + size and verified against the attempt/intent chain. First-created ONLY while the attempt is claimed (before SMTP) via transport.create_or_verify_send_mime_artifact. One artifact per attempt. The only legal UPDATE is the retention-clearing transition (raw_mime -> NULL + cleared_at stamped, metadata byte-identical) once the attempt is completed/failed_before_delivery/cancelled; mime_sha256/size_bytes/message_id survive clearing. Max 26214400 bytes (25 MiB). Unreachable by the browser; worker: SELECT/UPDATE only (never INSERT/DELETE). Parent attempt/intent/workspace FKs are ON DELETE CASCADE, so a full graph deletion removes derived artifacts.';
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
  -- (4) FIRST-INSERT STATE GATE (defect 5): an artifact may only be first
  -- created while the attempt is EXACTLY 'claimed' — i.e. after it has been
  -- leased but BEFORE SMTP is attempted. This guarantees the exact bytes exist
  -- and are bound to the confirmed intent before delivery starts; bytes can
  -- never be first-attached after smtp_in_progress / smtp_accepted /
  -- sent_copy_pending / a terminal state. Because it lives in the BEFORE INSERT
  -- trigger it fires for EVERY insert path, including a direct privileged INSERT.
  if v_attempt.state is distinct from 'claimed' then
    raise exception 'send_mime_artifacts may only be created while the attempt is claimed (state %)', coalesce(v_attempt.state, '<missing>')
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function transport.mime_artifacts_before_insert() is
  'Phase 3B integrity: an inserted MIME artifact must carry the exact bytes (sha256(raw_mime) = mime_sha256, raw_mime NOT NULL), be consistent with its parent chain (attempt belongs to the intent; intent''s workspace_id + message_id match the row), AND be first-created only while the attempt is EXACTLY in state ''claimed'' (so bytes can never appear after SMTP has already started, even on a direct privileged INSERT). 23514 on any violation.';

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
-- 3b. ATOMIC create-or-verify (defects 5 + 6). This SECURITY DEFINER function is
--     the worker's ONLY creation path — the worker holds NO direct INSERT. It
--     is safe under concurrency and under restart/reconciliation:
--       * It locks the attempt row FOR UPDATE, serializing two concurrent calls
--         for the same attempt; the unique(send_attempt_id) index backstops.
--       * FIRST-CREATE is allowed ONLY while the attempt is 'claimed' (belt &
--         suspenders with the BEFORE INSERT gate) and only when every bound
--         relationship + the exact-bytes hash/size hold.
--       * If an artifact already exists this is the restart/reconciliation VERIFY
--         path: it is permitted REGARDLESS of the current attempt state, but the
--         args must match the stored row's identity EXACTLY (and the bytes, when
--         still present). It NEVER overwrites existing bytes.
--     Every rejection raises a UNIFORM, non-disclosing 23514 so a caller cannot
--     tell which check failed.
-- ---------------------------------------------------------------------------
create or replace function transport.create_or_verify_send_mime_artifact(
  p_send_attempt_id uuid,
  p_send_intent_id uuid,
  p_workspace_id uuid,
  p_message_id text,
  p_mime_sha256 text,
  p_size_bytes bigint,
  p_raw_mime bytea
) returns transport.send_mime_artifacts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt_state text;
  v_attempt_intent uuid;
  v_intent public.send_intents;
  v_existing transport.send_mime_artifacts;
  v_row transport.send_mime_artifacts;
begin
  -- 1. Serialize concurrent callers for this attempt and read its state + intent.
  select a.state, a.send_intent_id
    into v_attempt_state, v_attempt_intent
  from public.send_attempts a
  where a.id = p_send_attempt_id
  for update;

  -- 2. Is there already an artifact for this attempt?
  select * into v_existing
  from transport.send_mime_artifacts
  where send_attempt_id = p_send_attempt_id;

  if found then
    -- 4. RESTART / RECONCILIATION VERIFY PATH. Permitted regardless of the
    -- attempt's current state, but the args must match the stored identity
    -- EXACTLY. The raw bytes are compared ONLY while still present (a cleared
    -- row keeps identity on its durable metadata: hash/size/message_id/refs).
    -- Any divergence -> uniform 23514. Existing bytes are NEVER overwritten.
    if v_existing.send_attempt_id is distinct from p_send_attempt_id
       or v_existing.send_intent_id is distinct from p_send_intent_id
       or v_existing.workspace_id is distinct from p_workspace_id
       or v_existing.message_id is distinct from p_message_id
       or v_existing.mime_sha256 is distinct from p_mime_sha256
       or v_existing.size_bytes is distinct from p_size_bytes
       or (v_existing.raw_mime is not null and v_existing.raw_mime is distinct from p_raw_mime) then
      raise exception 'send MIME artifact verify failed' using errcode = '23514';
    end if;
    return v_existing;
  end if;

  -- 3. FIRST-CREATE PATH. The attempt must be EXACTLY 'claimed' (uniform 23514).
  if v_attempt_state is distinct from 'claimed' then
    raise exception 'send MIME artifact create failed' using errcode = '23514';
  end if;
  -- Every bound relationship must hold: the attempt belongs to the intent, and
  -- the intent's workspace + Message-ID match the args (uniform 23514).
  if v_attempt_intent is distinct from p_send_intent_id then
    raise exception 'send MIME artifact create failed' using errcode = '23514';
  end if;
  select * into v_intent from public.send_intents i where i.id = p_send_intent_id;
  if not found
     or v_intent.workspace_id is distinct from p_workspace_id
     or v_intent.message_id is distinct from p_message_id then
    raise exception 'send MIME artifact create failed' using errcode = '23514';
  end if;
  -- Exact bytes: present, hashing to the declared sha256, of the declared size,
  -- within the 25 MiB (26214400-byte) bound (uniform 23514).
  if p_raw_mime is null
     or encode(sha256(p_raw_mime), 'hex') is distinct from p_mime_sha256
     or octet_length(p_raw_mime) is distinct from p_size_bytes
     or p_size_bytes > 26214400 then
    raise exception 'send MIME artifact create failed' using errcode = '23514';
  end if;

  -- INSERT exactly once. The BEFORE INSERT trigger re-checks state='claimed' and
  -- the whole parent chain (belt & suspenders); the unique(send_attempt_id)
  -- constraint backstops a concurrent double-create.
  insert into transport.send_mime_artifacts
    (send_attempt_id, send_intent_id, workspace_id, message_id, mime_sha256, size_bytes, raw_mime)
  values
    (p_send_attempt_id, p_send_intent_id, p_workspace_id, p_message_id, p_mime_sha256, p_size_bytes, p_raw_mime)
  returning * into v_row;
  return v_row;
end;
$$;
comment on function transport.create_or_verify_send_mime_artifact(uuid, uuid, uuid, text, text, bigint, bytea) is
  'Phase 3B (PRIVATE, SECURITY DEFINER): the worker''s ONLY creation path for send_mime_artifacts (the worker holds NO direct INSERT). Locks the attempt row FOR UPDATE (serializing concurrent identical calls; unique(send_attempt_id) backstops). If no artifact exists it FIRST-CREATES one, but only while the attempt is EXACTLY ''claimed'' and every bound relationship + the exact-bytes hash/size/25MiB-bound hold. If an artifact already exists it VERIFIES identity for the restart/reconciliation path — permitted regardless of the current attempt state, requiring an EXACT match on send_attempt_id/send_intent_id/workspace_id/message_id/mime_sha256/size_bytes (and raw_mime while still present), and NEVER overwriting existing bytes; a cleared row still verifies on its durable metadata. Every rejection is a UNIFORM, non-disclosing 23514. EXECUTE: transport_worker + service_role only.';

-- Creation is worker-only through this function; browsers can never call it.
revoke all on function transport.create_or_verify_send_mime_artifact(uuid, uuid, uuid, text, text, bigint, bytea)
  from public, anon, authenticated;
grant execute on function transport.create_or_verify_send_mime_artifact(uuid, uuid, uuid, text, text, bigint, bytea)
  to transport_worker, service_role;

-- ---------------------------------------------------------------------------
-- 3c. ARTIFACT-BEFORE-SMTP ordering guard (defect: the transition table permits
--     claimed -> smtp_in_progress, and nothing verified a MIME artifact exists,
--     so an attempt could enter smtp_in_progress with NO artifact — after which
--     artifact creation is PERMANENTLY impossible because the create/insert path
--     requires state='claimed'). This trigger refuses that one transition unless a
--     FULLY VALID, RETAINED artifact already exists, re-verifying the retained
--     bytes' hash/size at this one-time boundary (existence alone is not enough).
--
--     SECURITY INVOKER: the worker is the only role with UPDATE on
--     public.send_attempts and already holds SELECT on
--     transport.send_mime_artifacts, so the guard runs with exactly the
--     privileges the worker already has. Empty search_path; every object is fully
--     schema-qualified. It only READS the artifact table and NEW/OLD, so its
--     ordering relative to the existing BEFORE UPDATE guard
--     (trg_send_attempts_before_update) is immaterial.
-- ---------------------------------------------------------------------------
create or replace function transport.require_mime_artifact_before_smtp()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_valid_count integer;
begin
  -- Gated by the trigger's WHEN clause to fire ONLY on claimed ->
  -- smtp_in_progress. Require EXACTLY ONE fully-valid retained artifact for this
  -- attempt: bound to the same intent/workspace/message_id, bytes present and
  -- not cleared, within the 25 MiB bound, and — re-verified here at the one-time
  -- boundary rather than trusting mere row existence — whose retained bytes still
  -- hash and size to the stored durable digest/size.
  select count(*)
    into v_valid_count
  from transport.send_mime_artifacts m
  where m.send_attempt_id = new.id
    and m.send_intent_id = new.send_intent_id
    and m.workspace_id = new.workspace_id
    and m.message_id is not null
    and m.message_id = new.message_id
    and m.raw_mime is not null
    and m.cleared_at is null
    and m.size_bytes > 0
    and m.size_bytes <= 26214400
    and octet_length(m.raw_mime) = m.size_bytes
    and encode(sha256(m.raw_mime), 'hex') = m.mime_sha256;

  if v_valid_count <> 1 then
    -- Content-free, bounded message; the attempt stays in 'claimed'.
    raise exception 'send attempt cannot enter smtp_in_progress without a persisted MIME artifact'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function transport.require_mime_artifact_before_smtp() is
  'Phase 3B ordering guard: BEFORE UPDATE OF state on public.send_attempts, gated (WHEN) to the exact claimed -> smtp_in_progress transition. Refuses that transition (23514, content-free) unless EXACTLY ONE fully-valid RETAINED transport.send_mime_artifacts row exists for the attempt (same intent/workspace/message_id; raw_mime present, not cleared; 0 < size_bytes <= 26214400; octet_length(raw_mime) = size_bytes; sha256(raw_mime) = mime_sha256 — re-verified at this one-time boundary, not merely row existence). Closes the gap where an attempt could reach smtp_in_progress with no artifact, after which creation (state=claimed only) is impossible. SECURITY INVOKER; only READS, so ordering vs trg_send_attempts_before_update is immaterial.';

-- Internal machinery: nobody calls it directly. Grant EXECUTE to the roles that
-- perform the UPDATE it fires on (matching the repo''s function-grant convention);
-- the trigger executes as part of that worker/service_role UPDATE.
revoke all on function transport.require_mime_artifact_before_smtp()
  from public, anon, authenticated;
grant execute on function transport.require_mime_artifact_before_smtp()
  to transport_worker, service_role;

-- Guarded (drop-if-exists then create) so the migration is idempotent under the
-- suite's double-apply. BEFORE UPDATE OF state, fired only on the exact
-- claimed -> smtp_in_progress transition by the WHEN clause.
drop trigger if exists trg_send_attempts_require_mime_before_smtp on public.send_attempts;
create trigger trg_send_attempts_require_mime_before_smtp
  before update of state on public.send_attempts
  for each row
  when (old.state = 'claimed' and new.state = 'smtp_in_progress')
  execute function transport.require_mime_artifact_before_smtp();

-- ---------------------------------------------------------------------------
-- 4. Grants (revoke-then-grant; idempotent). anon/authenticated get NOTHING.
--    The worker gets exactly SELECT + UPDATE (UPDATE is the trigger-enforced
--    clearing transition only) — NEVER INSERT (creation is exclusively through
--    transport.create_or_verify_send_mime_artifact, a DEFINER-owned function)
--    and NEVER DELETE (so a clearing-only worker can never destroy the proof;
--    only a full parent/graph deletion by service_role/owner cascades it away).
--    service_role keeps operational ownership. uuid pk => no sequence privilege.
-- ---------------------------------------------------------------------------
revoke all on table transport.send_mime_artifacts from public, anon, authenticated, transport_worker;
grant select, update on table transport.send_mime_artifacts to transport_worker;
grant all on table transport.send_mime_artifacts to service_role;

-- RLS on with NO policies — defence in depth, exactly like mailbox_credentials.
-- The only roles that can reach the schema are BYPASSRLS; even a mistaken future
-- grant would still expose zero rows.
alter table transport.send_mime_artifacts enable row level security;

-- ============================================================================
-- End of migration 20260717100000_send_mime_artifacts.sql
-- ============================================================================
