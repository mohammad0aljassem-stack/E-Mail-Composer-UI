-- ============================================================================
-- Phase 3B — Confirmed send snapshots (exact draft binding for send intents)
-- Migration: 20260716100000_confirmed_send_snapshots.sql
--
-- Applied AFTER the existing chain:
--   baseline
--     -> 20260711130000_draft_lifecycle                (Phase 2)
--     -> 20260712100000_enforce_phase2_rpc_invariants  (Phase 2 hardening)
--     -> 20260713100000_transport_foundation           (Phase 3A; MERGED, sha256
--                                                       a2319ada…8c72a, UNCHANGED)
--     -> 20260714100000_transport_contract_hardening   (Phase 3A; MERGED, sha256
--                                                       ee064f0b…3977, UNCHANGED)
--     -> 20260715100000_worker_transition_grant        (Phase 3A; MERGED, sha256
--                                                       ca15b9de…4dba, UNCHANGED)
--     -> THIS
--
-- It is strictly ADDITIVE: it widens one CHECK constraint on
-- public.draft_versions (adds ONE new allowed reason), adds two nullable/
-- defaulted columns to public.send_intents, CREATE-OR-REPLACEs the
-- create_send_intent RPC, and adds two PRIVATE worker-only snapshot functions
-- in the transport schema. It never drops or rewrites any prior object and
-- never destroys data. Idempotency: every statement is guarded (add column if
-- not exists / create index if not exists / create or replace / guarded DO
-- blocks / drop-constraint-if-exists-then-re-add with the identical widened
-- definition / revoke-then-grant), so a re-run is a no-op-equivalent.
--
-- THE CORRECTED DEFECT — confirm-time content binding:
--   A send_intent recorded only draft_id + draft_revision plus client-supplied
--   content hashes. The mutable public.drafts row can be edited after
--   confirmation, so the worker had no server-owned copy of the EXACT bytes the
--   user approved. This migration makes create_send_intent, atomically in the
--   same transaction as the intent insert:
--     1. lock the draft row (FOR UPDATE),
--     2. require the EXACT current revision (P0409 on mismatch — the canonical
--        conflict code, matching the save_draft convention),
--     3. reuse-or-create an immutable public.draft_versions snapshot of the
--        confirmed content (reason = 'send_confirmation'),
--     4. bind the intent to that snapshot (send_intents.draft_version_id,
--        ON DELETE RESTRICT) and stamp proof_version = 2 (the confirmation
--        proof canonical now covers the exact snapshot reference).
--   The worker reads the confirmed content ONLY through the two PRIVATE
--   SECURITY DEFINER functions below — draft_versions itself gets NO table
--   grant to transport_worker. Legacy intents (proof_version 1, NULL
--   draft_version_id) are non-sendable fail-closed: transport.get_send_snapshot
--   raises P0002 for them.
--
-- Error-code conventions (mirror Phase 2 / Phase 3A):
--   P0409 revision / compare-and-set conflict   22023 invalid argument value
--   P0002 row not found / not accessible         42501 authentication required
--   55000 precondition failed (kill switch, disabled mailbox)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Allow the new snapshot reason on public.draft_versions.
--
-- Additive-in-effect: the re-added constraint is the ORIGINAL Phase 2 list plus
-- exactly one new value ('send_confirmation'), so every previously valid row
-- stays valid. drop-if-exists + re-add makes a re-run a no-op-equivalent.
-- ---------------------------------------------------------------------------
alter table public.draft_versions
  drop constraint if exists draft_versions_reason_allowed;
alter table public.draft_versions
  add constraint draft_versions_reason_allowed check (reason in (
    'initial', 'autosave_checkpoint', 'manual_checkpoint',
    'before_template', 'after_template',
    'before_signature', 'after_signature', 'restore',
    'send_confirmation'
  ));

-- ---------------------------------------------------------------------------
-- 2. Exact snapshot reference on public.send_intents.
--
-- Nullable and additive: a NULL value marks a LEGACY intent written before this
-- migration (proof_version 1). Such intents are non-sendable fail-closed — the
-- worker's snapshot accessor raises P0002 for them. Every intent written from
-- here on references its confirmed snapshot and carries proof_version = 2.
-- ---------------------------------------------------------------------------
alter table public.send_intents
  add column if not exists draft_version_id uuid;
comment on column public.send_intents.draft_version_id is
  'Phase 3B: the immutable public.draft_versions snapshot of the EXACT confirmed content, created (or reused) by create_send_intent atomically with the intent. ON DELETE RESTRICT — the referenced snapshot cannot be removed from under a confirmed intent. NULL marks a legacy (proof_version 1) intent, which is non-sendable fail-closed (transport.get_send_snapshot raises P0002).';

do $do$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'send_intents_draft_version_fk'
      and conrelid = 'public.send_intents'::regclass
  ) then
    alter table public.send_intents
      add constraint send_intents_draft_version_fk
      foreign key (draft_version_id) references public.draft_versions (id) on delete restrict;
  end if;
end
$do$;

create index if not exists idx_send_intents_draft_version on public.send_intents (draft_version_id);

alter table public.send_intents
  add column if not exists proof_version integer not null default 1;
comment on column public.send_intents.proof_version is
  'Phase 3B: version of the confirmation-proof canonical. 1 = legacy (inputs only, no snapshot binding); 2 = the canonical additionally covers proof_version and the exact draft_version_id snapshot reference. Legacy proof_version-1 intents are non-sendable fail-closed in the worker contract.';

do $do$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'send_intents_proof_version_allowed'
      and conrelid = 'public.send_intents'::regclass
  ) then
    alter table public.send_intents
      add constraint send_intents_proof_version_allowed
      check (proof_version in (1, 2));
  end if;
end
$do$;

-- ===========================================================================
-- 3. create_send_intent — confirm-time snapshot binding (CREATE OR REPLACE)
--
-- SAME signature, ALL 20260714100000 behavior preserved: the idempotency
-- fingerprint is UNCHANGED (computed from inputs only), the early
-- idempotency-return path stays FIRST, the uniform P0002 not-found, sender
-- authority, kill-switch/enabled checks, Message-ID generation, audit row and
-- seeded 'confirmed' attempt are all identical. NEW, after the draft lookup:
-- the draft row is LOCKED (FOR UPDATE), the EXACT revision is required (P0409
-- on mismatch), an immutable snapshot is reused-or-created, and the intent is
-- bound to it with proof_version = 2 — all in one transaction, so the snapshot
-- exists BEFORE the intent insert, atomically.
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
  v_draft_version_id uuid;  -- the immutable confirmed-content snapshot
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
  -- fields (message_id, confirmation_proof, draft_version_id, proof_version).
  -- Computed from INPUTS ONLY — unchanged from 20260714100000 — so it is
  -- available on the idempotency-hit path without any table lookup and identical
  -- replays keep matching intents written before this migration.
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

  -- IDEMPOTENT-REPLAY PATH FIRST (unchanged): a key hit returns the existing
  -- intent BEFORE any lock/revision/snapshot work below.
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

  -- CONFIRM-TIME SNAPSHOT BINDING (Phase 3B). Lock the draft row so nothing can
  -- mutate it between the revision gate, the snapshot, and the intent insert —
  -- the snapshot below is guaranteed to be the exact content the user confirmed.
  select * into v_draft from public.drafts where id = p_draft_id for update;
  if not found or v_draft.workspace_id <> p_workspace_id then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;

  -- Exact-revision gate: the confirmation is only valid against the CURRENT
  -- draft revision (canonical conflict code, matching the save_draft convention).
  if v_draft.revision <> p_draft_revision then
    raise exception 'draft revision mismatch (expected %, has %)', p_draft_revision, v_draft.revision
      using errcode = 'P0409', hint = 'current_revision=' || v_draft.revision;
  end if;

  -- Snapshot reuse-or-create: if the newest version row for this draft already
  -- captures exactly this (source_revision, subject, body_json), reuse it;
  -- otherwise append an immutable 'send_confirmation' snapshot. Same
  -- transaction as the intent insert — the snapshot exists BEFORE the intent,
  -- atomically, and a failure after this point rolls both back.
  select dv.id into v_draft_version_id
  from public.draft_versions dv
  where dv.draft_id = p_draft_id
    and dv.source_revision = p_draft_revision
    and dv.subject = v_draft.subject
    and dv.body_json = v_draft.body_json
  order by dv.version_no desc
  limit 1;
  if v_draft_version_id is null then
    insert into public.draft_versions
      (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
    select v_draft.workspace_id, v_draft.id,
           coalesce(max(dv.version_no), 0) + 1,
           p_draft_revision, v_draft.subject, v_draft.body_json, 'send_confirmation', v_uid
    from public.draft_versions dv
    where dv.draft_id = p_draft_id
    returning id into v_draft_version_id;
  end if;

  -- Server-generate the RFC 5322 Message-ID from the MAILBOX domain (authoritative),
  -- never from client-controlled p_sender.
  v_domain := nullif(split_part(v_mailbox.email_address, '@', 2), '');
  if v_domain is null then
    v_domain := 'mail.local';
  end if;
  v_message_id := '<' || gen_random_uuid()::text || '@' || v_domain || '>';

  -- Server-compute the confirmation proof over the canonical snapshot (using the
  -- normalized authoritative sender). Proof v2: the canonical additionally binds
  -- the exact confirmed-content snapshot (draft_version_id) and its own version.
  -- jsonb normalizes key order, so the digest is deterministic for identical input.
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
    'confirmed_by', v_uid,
    'proof_version', 2,
    'draft_version_id', v_draft_version_id
  );
  v_proof := encode(sha256(convert_to(v_canonical::text, 'UTF8')), 'hex');

  insert into public.send_intents (
    workspace_id, mailbox_id, draft_id, draft_revision, sender, recipients,
    subject, html_hash, text_hash, attachment_manifest, message_id,
    idempotency_key, template_version_id, signature_id, contract_version,
    confirmed_by, confirmation_proof, request_fingerprint,
    draft_version_id, proof_version
  ) values (
    p_workspace_id, p_mailbox_id, p_draft_id, p_draft_revision, v_sender, v_recipients,
    v_subject, p_html_hash, p_text_hash, v_manifest, v_message_id,
    v_idem, p_template_version_id, p_signature_id, v_contract,
    v_uid, v_proof, v_fingerprint,
    v_draft_version_id, 2
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
  'Phase 3A/3B RPC (SECURITY DEFINER): the ONLY write path for send_intents. Verifies membership + mailbox/draft ownership + kill switch/enabled. SENDER AUTHORITY: rejects (22023) any p_sender that does not exactly match the mailbox address after trim+lowercase; derives the Message-ID domain from the MAILBOX address; stores the normalized authoritative sender. STRICT IDEMPOTENCY: stores a deterministic input-only request fingerprint and, on an idempotency-key hit, returns the existing intent only if the fingerprint matches, else raises P0409; non-members get a uniform P0002 (no existence leak). CONFIRM-TIME SNAPSHOT (Phase 3B): locks the draft (FOR UPDATE), requires the EXACT current revision (P0409 on mismatch, save_draft convention), reuses-or-creates an immutable draft_versions snapshot (reason=send_confirmation) of the confirmed content, and binds the intent to it (draft_version_id, proof_version=2) — snapshot, intent, seeded confirmed attempt and content-free audit event are all one atomic transaction.';

-- ===========================================================================
-- 4. PRIVATE worker-only snapshot accessors (transport schema)
--
-- The worker reads confirmed content ONLY through these two SECURITY DEFINER
-- functions — public.draft_versions gets NO table grant to transport_worker
-- anywhere. Both fail closed with P0002 on any missing row or cross-reference
-- inconsistency. DEFINER style matches the repo convention: empty search_path,
-- fully schema-qualified, revoke-then-grant to exactly transport_worker +
-- service_role.
-- ===========================================================================

-- 4.1 transport.get_send_snapshot — the EXACT confirmed content of one intent.
create or replace function transport.get_send_snapshot(p_send_intent_id uuid)
returns table (
  draft_version_id uuid,
  workspace_id uuid,
  draft_id uuid,
  source_revision bigint,
  version_no bigint,
  subject text,
  body_json jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_intent public.send_intents;
  v_version public.draft_versions;
begin
  select * into v_intent from public.send_intents i where i.id = p_send_intent_id;
  if not found then
    raise exception 'send intent not found' using errcode = 'P0002';
  end if;
  -- Legacy intents (proof_version 1) carry no snapshot binding: fail closed —
  -- they are non-sendable under the v2 worker contract.
  if v_intent.draft_version_id is null then
    raise exception 'send intent has no confirmed snapshot (legacy intent; non-sendable)'
      using errcode = 'P0002';
  end if;
  select * into v_version from public.draft_versions dv where dv.id = v_intent.draft_version_id;
  -- The referenced snapshot must exist and be consistent with the intent's own
  -- workspace/draft; any inconsistency fails closed with the uniform P0002.
  if not found
     or v_version.workspace_id is distinct from v_intent.workspace_id
     or v_version.draft_id is distinct from v_intent.draft_id then
    raise exception 'confirmed snapshot not found or inconsistent with its intent'
      using errcode = 'P0002';
  end if;
  return query select
    v_version.id, v_version.workspace_id, v_version.draft_id,
    v_version.source_revision, v_version.version_no,
    v_version.subject, v_version.body_json;
end;
$$;
comment on function transport.get_send_snapshot(uuid) is
  'Phase 3B (PRIVATE, SECURITY DEFINER): the worker''s ONLY read path for confirmed send content. Returns exactly the draft_versions snapshot referenced by the intent''s draft_version_id, after asserting the snapshot''s workspace/draft match the intent''s (P0002 on any miss or inconsistency). A legacy intent with NULL draft_version_id fails closed with P0002 — non-sendable. EXECUTE: transport_worker + service_role only; draft_versions itself has NO worker table grant.';

-- 4.2 transport.get_mirror_snapshot — newest snapshot of one exact revision
--     (workspace-scoped; used by the draft-mirror path, never for sending).
create or replace function transport.get_mirror_snapshot(
  p_workspace_id uuid,
  p_draft_id uuid,
  p_source_revision bigint
)
returns table (
  draft_version_id uuid,
  version_no bigint,
  subject text,
  body_json jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version public.draft_versions;
begin
  select * into v_version
  from public.draft_versions dv
  where dv.workspace_id = p_workspace_id
    and dv.draft_id = p_draft_id
    and dv.source_revision = p_source_revision
  order by dv.version_no desc
  limit 1;
  if not found then
    raise exception 'no snapshot for this workspace/draft/revision' using errcode = 'P0002';
  end if;
  return query select
    v_version.id, v_version.version_no, v_version.subject, v_version.body_json;
end;
$$;
comment on function transport.get_mirror_snapshot(uuid, uuid, bigint) is
  'Phase 3B (PRIVATE, SECURITY DEFINER): newest draft_versions snapshot for one EXACT (workspace, draft, source_revision) triple — the worker''s read path for mirroring a known revision. P0002 when no such snapshot exists (including any workspace mismatch: the workspace is part of the exact-match key). EXECUTE: transport_worker + service_role only; draft_versions itself has NO worker table grant.';

-- Function grants: revoke-then-grant; worker + service_role only, never the
-- browser roles (they also lack USAGE on schema transport — belt AND suspenders).
revoke all on function transport.get_send_snapshot(uuid) from public, anon, authenticated;
revoke all on function transport.get_mirror_snapshot(uuid, uuid, bigint) from public, anon, authenticated;
grant execute on function transport.get_send_snapshot(uuid) to transport_worker, service_role;
grant execute on function transport.get_mirror_snapshot(uuid, uuid, bigint) to transport_worker, service_role;

-- ============================================================================
-- End of migration 20260716100000_confirmed_send_snapshots.sql
-- ============================================================================
