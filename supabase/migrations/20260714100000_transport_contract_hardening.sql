-- ============================================================================
-- Phase 3A — Transport contract hardening (corrective, additive, idempotent)
-- Migration: 20260714100000_transport_contract_hardening.sql
--
-- Applied AFTER the existing chain:
--   baseline
--     -> 20260711130000_draft_lifecycle          (Phase 2)
--     -> 20260712100000_enforce_phase2_rpc_invariants (Phase 2 hardening)
--     -> 20260713100000_transport_foundation     (Phase 3A foundation; MERGED,
--                                                  sha256 a2319ada…8c72a, UNCHANGED)
--     -> THIS
--
-- It is strictly ADDITIVE: it CREATE-OR-REPLACEs the two Phase 3A RPCs, adds a
-- new PRIVATE table (transport.sync_requests), adds one nullable column to
-- public.send_intents, and (re-)asserts grants. It never drops or rewrites any
-- object created by the foundation migration and never destroys data.
--
-- Idempotency: every statement is guarded (create ... if not exists /
-- create or replace / add column if not exists / create unique index if not
-- exists / revoke-then-grant), so a re-run is a no-op.
--
-- The three corrected defects (see docs/security/phase-3a-transport-review.md):
--   1. Sender authority  — create_send_intent no longer trusts p_sender. The
--      authoritative address is transport-owned public.mailboxes.email_address;
--      p_sender must EXACTLY match it after normalization (trim + lowercase) or
--      the call is rejected (22023). The RFC 5322 Message-ID domain is derived
--      from the MAILBOX address, never from p_sender.
--   2. Durable sync request — request_mailbox_sync now writes a durable, claimable
--      row in transport.sync_requests (deduped per mailbox(+folder) while open)
--      in the same transaction as its content-free audit event, and returns the
--      durable request id/status. The worker claims it (PR B enqueues/executes).
--   3. Strict idempotency — create_send_intent stores a deterministic request
--      fingerprint. An idempotency-key hit returns the existing intent ONLY when
--      the recomputed fingerprint matches; a divergent payload raises P0409.
--      Non-members still get a uniform P0002 (no existence / P0409 leak).
--
-- Error-code conventions (mirror Phase 2 / the foundation):
--   P0409 idempotency-key reused with a divergent payload
--   P0002 row not found / not accessible (uniform, no cross-workspace leak)
--   22023 invalid argument value (incl. sender-authority mismatch)
--   42501 authentication required            55000 precondition failed
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Strict-idempotency support column on public.send_intents
--
-- Nullable and additive (the table is new/empty in practice). Populated by
-- create_send_intent on every insert. A NULL value marks a legacy row written
-- before this migration; such rows are treated as "cannot prove divergence" and
-- returned as-is on replay (no false P0409). Every row written from here on
-- carries a fingerprint, so divergence is caught strictly for all new intents.
-- ---------------------------------------------------------------------------
-- The column is added with `if not exists`; all existing values are NULL (which
-- the format CHECK permits), so no table scan / rewrite of real data occurs. The
-- CHECK is attached in a separate guarded step so a re-run stays a no-op.
alter table public.send_intents
  add column if not exists request_fingerprint text;
comment on column public.send_intents.request_fingerprint is
  'Phase 3A hardening: sha256 (hex) over the canonical request payload (workspace/mailbox/draft/revision/normalized sender/recipients/subject/body hashes/attachment manifest/template/signature/contract version; EXCLUDES server-generated message_id + confirmation_proof). Enables strict idempotency: an idempotency-key hit with a divergent fingerprint raises P0409.';

do $do$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'send_intents_request_fingerprint_format'
      and conrelid = 'public.send_intents'::regclass
  ) then
    alter table public.send_intents
      add constraint send_intents_request_fingerprint_format
      check (request_fingerprint is null or request_fingerprint ~ '^[a-f0-9]{64}$');
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- 2. transport.sync_requests (PRIVATE — durable, claimable mailbox-sync request)
--
-- Rewrites request_mailbox_sync from a fire-and-forget audit stub into a durable
-- work item the worker can atomically claim. anon/authenticated get ZERO access
-- (the schema is already private; no grants are added for them). transport_worker
-- gets exactly SELECT + UPDATE (claim: set status/claimed_at/completed_at/
-- attempt_count/last_error). service_role gets ALL. The RPC (SECURITY DEFINER)
-- performs the INSERT, so the worker needs no INSERT.
-- ---------------------------------------------------------------------------
create table if not exists transport.sync_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  mailbox_id uuid not null references public.mailboxes (id) on delete cascade,
  -- NULL folder == whole-mailbox sync. A specific folder narrows the request.
  folder text
    constraint sync_requests_folder_len check (folder is null or char_length(folder) between 1 and 1024),
  status text not null default 'pending'
    constraint sync_requests_status_allowed check (status in ('pending', 'claimed', 'completed', 'failed')),
  requested_by uuid references public.users (id),
  requested_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  attempt_count integer not null default 0
    constraint sync_requests_attempt_count_nonneg check (attempt_count >= 0),
  -- Content-free, bounded. Holds an error CODE/short reason only — never any
  -- message content, credential material, or provider payload.
  last_error text
    constraint sync_requests_last_error_len check (last_error is null or char_length(last_error) <= 2000)
);
comment on table transport.sync_requests is
  'Phase 3A hardening (PRIVATE): durable, claimable mailbox-sync requests. request_mailbox_sync upserts a pending row (deduped per mailbox(+folder) while open); the worker claims exactly one (SELECT/UPDATE) and drives status pending->claimed->completed/failed. NULL folder == whole mailbox. last_error is content-free. Unreachable by the browser.';
comment on column transport.sync_requests.folder is
  'NULL == whole-mailbox sync; a non-null value narrows the request to one folder. Part of the open-request dedup key (coalesced to '''' so two whole-mailbox requests collide).';
comment on column transport.sync_requests.last_error is
  'Content-free, bounded (<=2000 chars): an error code / short non-content reason only. NEVER message bodies, credentials, or provider payloads.';

create index if not exists idx_sync_requests_mailbox_id on transport.sync_requests (mailbox_id);
create index if not exists idx_sync_requests_workspace_id on transport.sync_requests (workspace_id);
create index if not exists idx_sync_requests_status on transport.sync_requests (status);

-- Dedup: at most ONE open (pending|claimed) request per mailbox(+folder).
-- folder is coalesced to '' so two whole-mailbox (NULL-folder) open requests
-- collide instead of being treated as distinct NULLs. Doubles as the ON CONFLICT
-- arbiter for the RPC's atomic upsert.
create unique index if not exists uq_sync_requests_open
  on transport.sync_requests (mailbox_id, coalesce(folder, ''))
  where status in ('pending', 'claimed');

-- RLS on with NO policies — defence in depth, exactly like the other transport
-- tables. The only roles that can reach the schema are BYPASSRLS.
alter table transport.sync_requests enable row level security;

-- ===========================================================================
-- 3. create_send_intent — sender authority + strict idempotency (CREATE OR REPLACE)
-- ===========================================================================
create or replace function public.create_send_intent(
  p_workspace_id uuid,
  p_mailbox_id uuid,
  p_draft_id uuid,
  p_draft_revision bigint,
  p_sender text,
  p_recipients jsonb,
  p_subject text,
  p_html_hash text,
  p_text_hash text,
  p_attachment_manifest jsonb,
  p_template_version_id uuid default null,
  p_signature_id uuid default null,
  p_contract_version integer default 1,
  p_idempotency_key text default null
) returns public.send_intents
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_mailbox public.mailboxes;
  v_draft public.drafts;
  v_existing public.send_intents;
  v_intent public.send_intents;
  v_idem text;
  v_domain text;
  v_message_id text;
  v_subject text := coalesce(p_subject, '');
  v_recipients jsonb := coalesce(p_recipients, '{}'::jsonb);
  v_manifest jsonb := coalesce(p_attachment_manifest, '[]'::jsonb);
  v_contract integer := coalesce(p_contract_version, 1);
  v_sender text;            -- normalized (authoritative) sender: trim + lowercase
  v_mailbox_addr text;      -- normalized mailbox.email_address
  v_fingerprint text;       -- deterministic request fingerprint (strict idempotency)
  v_fp_canonical jsonb;
  v_proof text;
  v_canonical jsonb;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Argument validation (before any lookup).
  if p_draft_revision is null or p_draft_revision <= 0 then
    raise exception 'draft_revision must be positive' using errcode = '22023';
  end if;
  -- Normalize the sender ONCE (documented normalization: trim + lowercase), THEN
  -- validate the normalized value's format. The same normalized value is reused
  -- for the fingerprint, the sender-authority comparison, and the stored
  -- authoritative sender, so they can never diverge.
  if p_sender is null then
    raise exception 'sender must be a valid email address' using errcode = '22023';
  end if;
  v_sender := lower(btrim(p_sender));
  if v_sender !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    raise exception 'sender must be a valid email address' using errcode = '22023';
  end if;
  if jsonb_typeof(v_recipients) <> 'object'
     or jsonb_typeof(v_recipients -> 'to') is distinct from 'array'
     or jsonb_array_length(v_recipients -> 'to') = 0 then
    raise exception 'recipients must be an object with a non-empty "to" array' using errcode = '22023';
  end if;
  if jsonb_typeof(v_manifest) <> 'array' then
    raise exception 'attachment_manifest must be a JSON array' using errcode = '22023';
  end if;
  if p_html_hash is not null and p_html_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'html_hash must be 64 lowercase hex characters' using errcode = '22023';
  end if;
  if p_text_hash is not null and p_text_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'text_hash must be 64 lowercase hex characters' using errcode = '22023';
  end if;
  if v_contract <= 0 then
    raise exception 'contract_version must be positive' using errcode = '22023';
  end if;

  -- Strict-idempotency fingerprint: a deterministic sha256 over the CANONICAL
  -- request payload. jsonb normalizes key order + nested structure, so identical
  -- requests hash identically and any changed field changes the digest. It
  -- INCLUDES the normalized (authoritative) sender and EXCLUDES server-generated
  -- fields (message_id, confirmation_proof). Computed from inputs only, so it is
  -- available on the idempotency-hit path without any table lookup.
  v_fp_canonical := jsonb_build_object(
    'workspace_id', p_workspace_id,
    'mailbox_id', p_mailbox_id,
    'draft_id', p_draft_id,
    'draft_revision', p_draft_revision,
    'sender', v_sender,
    'recipients', v_recipients,
    'subject', v_subject,
    'html_hash', p_html_hash,
    'text_hash', p_text_hash,
    'attachment_manifest', v_manifest,
    'template_version_id', p_template_version_id,
    'signature_id', p_signature_id,
    'contract_version', v_contract
  );
  v_fingerprint := encode(sha256(convert_to(v_fp_canonical::text, 'UTF8')), 'hex');

  -- Idempotency: a client-supplied key makes retries safe; absent, generate one.
  v_idem := coalesce(nullif(p_idempotency_key, ''), gen_random_uuid()::text);
  if char_length(v_idem) > 255 then
    raise exception 'idempotency_key must be at most 255 characters' using errcode = '22023';
  end if;

  select * into v_existing from public.send_intents where idempotency_key = v_idem;
  if found then
    -- Uniform not-found for non-members FIRST — never leak existence (P0002, not
    -- P0409) across workspaces.
    if not public.is_workspace_member(v_existing.workspace_id) then
      raise exception 'mailbox not found or access denied' using errcode = 'P0002';
    end if;
    -- Strict idempotency: same key must mean same payload. A stored fingerprint
    -- that differs from the recomputed one means the caller reused the key with a
    -- changed payload -> conflict. (NULL stored fingerprint = legacy row: cannot
    -- prove divergence, so return it as-is.)
    if v_existing.request_fingerprint is not null
       and v_existing.request_fingerprint <> v_fingerprint then
      raise exception 'idempotency_key reused with a different payload'
        using errcode = 'P0409';
    end if;
    return v_existing;
  end if;

  -- Authorization: caller must be a member of the claimed workspace, and the
  -- mailbox + draft must both belong to it. DEFINER bypasses RLS, so every
  -- check is explicit.
  if p_workspace_id is null or not public.is_workspace_member(p_workspace_id) then
    raise exception 'mailbox not found or access denied' using errcode = 'P0002';
  end if;

  select * into v_mailbox from public.mailboxes where id = p_mailbox_id;
  if not found or v_mailbox.workspace_id <> p_workspace_id then
    raise exception 'mailbox not found or access denied' using errcode = 'P0002';
  end if;

  -- SENDER AUTHORITY: the authoritative sender is the transport-owned mailbox
  -- address (unique per workspace), NEVER the client-supplied p_sender. Reject
  -- any p_sender that does not EXACTLY match it after the documented normalization
  -- (trim + lowercase). This raises BEFORE any intent/attempt/audit row is
  -- written, so a rejected call leaves no trace.
  v_mailbox_addr := lower(btrim(v_mailbox.email_address));
  if v_sender <> v_mailbox_addr then
    raise exception 'sender must exactly match the mailbox address (after trim+lowercase)'
      using errcode = '22023';
  end if;

  if v_mailbox.kill_switch then
    raise exception 'mailbox kill switch is engaged' using errcode = '55000';
  end if;
  if not v_mailbox.enabled then
    raise exception 'mailbox is not enabled' using errcode = '55000';
  end if;

  select * into v_draft from public.drafts where id = p_draft_id;
  if not found or v_draft.workspace_id <> p_workspace_id then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;

  -- Server-generate the RFC 5322 Message-ID from the MAILBOX domain (authoritative),
  -- never from client-controlled p_sender.
  v_domain := nullif(split_part(v_mailbox.email_address, '@', 2), '');
  if v_domain is null then
    v_domain := 'mail.local';
  end if;
  v_message_id := '<' || gen_random_uuid()::text || '@' || v_domain || '>';

  -- Server-compute the confirmation proof over the canonical snapshot (using the
  -- normalized authoritative sender). jsonb normalizes key order, so the digest
  -- is deterministic for identical input.
  v_canonical := jsonb_build_object(
    'workspace_id', p_workspace_id,
    'mailbox_id', p_mailbox_id,
    'draft_id', p_draft_id,
    'draft_revision', p_draft_revision,
    'sender', v_sender,
    'recipients', v_recipients,
    'subject', v_subject,
    'html_hash', p_html_hash,
    'text_hash', p_text_hash,
    'attachment_manifest', v_manifest,
    'template_version_id', p_template_version_id,
    'signature_id', p_signature_id,
    'message_id', v_message_id,
    'contract_version', v_contract,
    'confirmed_by', v_uid
  );
  v_proof := encode(sha256(convert_to(v_canonical::text, 'UTF8')), 'hex');

  insert into public.send_intents (
    workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
    subject, html_hash, text_hash, attachment_manifest, message_id,
    idempotency_key, template_version_id, signature_id, contract_version,
    confirmed_by, confirmation_proof, request_fingerprint
  ) values (
    p_workspace_id, p_mailbox_id, p_draft_id, p_draft_revision, v_sender, v_recipients,
    v_subject, p_html_hash, p_text_hash, v_manifest, v_message_id,
    v_idem, p_template_version_id, p_signature_id, v_contract,
    v_uid, v_proof, v_fingerprint
  ) returning * into v_intent;

  -- Seed the outbound state machine in 'confirmed' (the intent IS the
  -- confirmation) and record a content-free audit event.
  insert into public.send_attempts (workspace_id, send_intent_id, state, message_id)
  values (v_intent.workspace_id, v_intent.id, 'confirmed', v_intent.message_id);

  insert into public.transport_audit
    (workspace_id, mailbox_id, event_type, send_intent_id, message_id)
  values
    (v_intent.workspace_id, v_intent.mailbox_id, 'send_intent_created', v_intent.id, v_intent.message_id);

  return v_intent;
end;
$$;
comment on function public.create_send_intent(uuid, uuid, uuid, bigint, text, jsonb, text, text, text, jsonb, uuid, uuid, integer, text) is
  'Phase 3A RPC (SECURITY DEFINER): the ONLY write path for send_intents. Verifies membership + mailbox/draft ownership + kill switch/enabled. SENDER AUTHORITY: rejects (22023) any p_sender that does not exactly match the mailbox address after trim+lowercase; derives the Message-ID domain from the MAILBOX address; stores the normalized authoritative sender. STRICT IDEMPOTENCY: stores a deterministic request fingerprint and, on an idempotency-key hit, returns the existing intent only if the fingerprint matches, else raises P0409; non-members get a uniform P0002 (no existence leak). Inserts the immutable intent, seeds a send_attempt in state=confirmed, and appends a content-free audit event, atomically.';

-- ===========================================================================
-- 4. request_mailbox_sync — durable, deduped, claimable request (CREATE OR REPLACE)
-- ===========================================================================
create or replace function public.request_mailbox_sync(
  p_mailbox_id uuid,
  p_workspace_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_mailbox public.mailboxes;
  v_req transport.sync_requests;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_workspace_id is null or not public.is_workspace_member(p_workspace_id) then
    raise exception 'mailbox not found or access denied' using errcode = 'P0002';
  end if;

  select * into v_mailbox from public.mailboxes where id = p_mailbox_id;
  if not found or v_mailbox.workspace_id <> p_workspace_id then
    raise exception 'mailbox not found or access denied' using errcode = 'P0002';
  end if;
  if v_mailbox.kill_switch then
    raise exception 'mailbox kill switch is engaged' using errcode = '55000';
  end if;
  if not v_mailbox.enabled then
    raise exception 'mailbox is not enabled' using errcode = '55000';
  end if;

  -- Atomically upsert/dedup a durable whole-mailbox (folder = NULL) request: if an
  -- OPEN (pending|claimed) request already exists for this mailbox, return it
  -- unchanged; otherwise insert a fresh pending one. The partial-unique index
  -- uq_sync_requests_open is the arbiter (folder coalesced to '' so whole-mailbox
  -- requests collide). The no-op DO UPDATE makes RETURNING surface the existing
  -- open row. No IMAP here — the worker claims this row and does the actual sync.
  insert into transport.sync_requests (workspace_id, mailbox_id, folder, status, requested_by)
  values (v_mailbox.workspace_id, v_mailbox.id, null, 'pending', v_uid)
  on conflict (mailbox_id, coalesce(folder, '')) where status in ('pending', 'claimed')
  do update set attempt_count = transport.sync_requests.attempt_count
  returning * into v_req;

  -- Content-free audit event, same transaction as the durable upsert.
  insert into public.transport_audit (workspace_id, mailbox_id, event_type, detail)
  values (
    v_mailbox.workspace_id, v_mailbox.id, 'mailbox_sync_requested',
    jsonb_build_object('sync_request_id', v_req.id, 'status', v_req.status)
  );

  -- Return the DURABLE request id/status; the worker claims it.
  return jsonb_build_object(
    'sync_request_id', v_req.id,
    'mailbox_id', v_mailbox.id,
    'folder', v_req.folder,
    'status', v_req.status,
    'requested_at', v_req.requested_at
  );
end;
$$;
comment on function public.request_mailbox_sync(uuid, uuid) is
  'Phase 3A RPC (SECURITY DEFINER): a member asks the worker to sync a mailbox. Validates membership + ownership + enabled/kill-switch, then ATOMICALLY upserts a durable, claimable transport.sync_requests row (deduped per mailbox while an open pending|claimed request exists — returns the existing one) AND appends a content-free audit event, in one transaction. Returns the durable request id/status. Performs NO IMAP in SQL; the worker claims the row (SELECT/UPDATE) and PR B enqueues/executes the sync.';

-- ===========================================================================
-- 5. Grants (revoke-then-grant; idempotent)
-- ===========================================================================

-- 5.1 transport.sync_requests: anon/authenticated NOTHING; worker exactly
--     SELECT+UPDATE (claim); service_role ALL. The RPC (DEFINER) does the INSERT,
--     so the worker needs no INSERT.
revoke all on table transport.sync_requests from public, anon, authenticated;
grant select, update on table transport.sync_requests to transport_worker;
grant all on table transport.sync_requests to service_role;

-- 5.2 Re-assert the RPC EXECUTE grants. CREATE OR REPLACE preserves the existing
--     ACL, but we re-assert to be safe + idempotent: never anon/public; only
--     authenticated + service_role.
revoke execute on function
  public.create_send_intent(uuid, uuid, uuid, bigint, text, jsonb, text, text, text, jsonb, uuid, uuid, integer, text)
  from public, anon;
revoke execute on function public.request_mailbox_sync(uuid, uuid) from public, anon;

grant execute on function
  public.create_send_intent(uuid, uuid, uuid, bigint, text, jsonb, text, text, text, jsonb, uuid, uuid, integer, text)
  to authenticated, service_role;
grant execute on function public.request_mailbox_sync(uuid, uuid) to authenticated, service_role;

-- ============================================================================
-- End of migration 20260714100000_transport_contract_hardening.sql
-- ============================================================================
