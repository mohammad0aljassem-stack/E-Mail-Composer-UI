-- ============================================================================
-- Phase 3A — Transport foundation (mailboxes, sync metadata, send intents,
--            outbound state machine, worker-only secrets)
-- Migration: 20260713100000_transport_foundation.sql
--
-- Strictly ADDITIVE on top of the Phase 2 chain (20260711130000_draft_lifecycle
-- + 20260712100000_enforce_phase2_rpc_invariants). It only CREATEs new objects
-- (a private schema, tables, triggers, functions, policies, one local worker
-- role) and never alters or drops any Phase 1/2 object. Idempotency guards
-- (CREATE ... IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS /
-- guarded DO blocks / revoke-then-grant) make a re-run a no-op.
--
-- SECURITY SEPARATION (the core design decision):
--   * public.*   — workspace-facing METADATA, RLS-protected, readable by the
--     browser through PostgREST. authenticated gets SELECT only; every mutation
--     is either a SECURITY DEFINER RPC or a worker-only write. NO secrets, NO
--     message bodies, NO credentials live here.
--   * transport.* — a PRIVATE schema that is NOT exposed to PostgREST. anon and
--     authenticated get ZERO access (no schema USAGE, no table privileges).
--     Only the dedicated worker role and service_role may touch it. Credential
--     ciphertext / nonce / auth tag / key version and worker lease/heartbeat
--     rows live here and can NEVER reach the browser.
--
-- Error-code conventions (mirror Phase 2):
--   P0409 revision / compare-and-set conflict   22023 invalid argument value
--   P0002 row not found / not accessible         42501 authentication required
--   23514 integrity-trigger violation (immutability / illegal transition)
--   55000 precondition failed (kill switch, disabled mailbox)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Private schema + local worker role
--
-- The worker role is created NOLOGIN with NO password: production provisions
-- the real login credential out of band (a separate manual op — see
-- docs/security/phase-3a-transport-review.md). It is BYPASSRLS because it is a
-- system actor that operates across ALL workspaces (it syncs every enabled
-- mailbox); workspace-scoped RLS is meaningless for it. Its privilege boundary
-- is therefore the explicit, narrow set of table grants below — it never gets
-- broad write on the public schema (only the specific transport tables it
-- needs), exactly like a least-privilege service account.
-- ---------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from pg_roles where rolname = 'transport_worker') then
    create role transport_worker nologin noinherit bypassrls;
  end if;
end
$do$;

create schema if not exists transport;
comment on schema transport is
  'Phase 3A: PRIVATE transport schema. Never exposed to PostgREST. anon/authenticated have no USAGE; only transport_worker + service_role may access it. Holds credential ciphertext and worker lease/heartbeat rows.';

-- Lock the schema down FIRST (defeats any inherited/default privilege), then
-- hand USAGE only to the worker + service_role.
revoke all on schema transport from public, anon, authenticated;
grant usage on schema transport to transport_worker, service_role;

-- The worker needs to reach the public transport tables it mutates; it does
-- NOT get CREATE on public. (authenticated/anon USAGE on public is unchanged
-- from the baseline.)
grant usage on schema public to transport_worker;

-- ===========================================================================
-- 1. public tables (workspace-facing metadata; RLS; SELECT-only for members)
-- ===========================================================================

-- 1.1 mailboxes --------------------------------------------------------------
create table if not exists public.mailboxes (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  provider text not null default 'imap_smtp'
    constraint mailboxes_provider_allowed check (provider in ('imap_smtp')),
  email_address text not null
    constraint mailboxes_email_format check (
      char_length(email_address) between 3 and 320
      and email_address ~ '^[^@[:space:]]+@[^@[:space:]]+$'
    ),
  display_name text
    constraint mailboxes_display_name_max_len check (display_name is null or char_length(display_name) <= 200),
  imap_host text
    constraint mailboxes_imap_host_max_len check (imap_host is null or char_length(imap_host) <= 255),
  imap_port integer
    constraint mailboxes_imap_port_range check (imap_port is null or (imap_port between 1 and 65535)),
  imap_security text
    constraint mailboxes_imap_security_allowed check (imap_security is null or imap_security in ('ssl', 'starttls', 'none')),
  smtp_host text
    constraint mailboxes_smtp_host_max_len check (smtp_host is null or char_length(smtp_host) <= 255),
  smtp_port integer
    constraint mailboxes_smtp_port_range check (smtp_port is null or (smtp_port between 1 and 65535)),
  smtp_security text
    constraint mailboxes_smtp_security_allowed check (smtp_security is null or smtp_security in ('ssl', 'starttls', 'none')),
  enabled boolean not null default false,
  kill_switch boolean not null default false,
  last_synced_at timestamptz,
  created_by uuid not null references public.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mailboxes_workspace_email_uq unique (workspace_id, email_address)
);
comment on table public.mailboxes is
  'Phase 3A: workspace-scoped mailbox metadata (non-secret IMAP/SMTP host/port/security config). Contains NO passwords — credentials live encrypted in transport.mailbox_credentials. authenticated: SELECT only.';
comment on column public.mailboxes.kill_switch is
  'Phase 3A: hard per-mailbox stop. When true, create_send_intent refuses and the worker must not send.';

create index if not exists idx_mailboxes_workspace_id on public.mailboxes (workspace_id);
create index if not exists idx_mailboxes_workspace_enabled on public.mailboxes (workspace_id, enabled);

-- 1.2 mailbox_folders --------------------------------------------------------
create table if not exists public.mailbox_folders (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  mailbox_id uuid not null references public.mailboxes (id) on delete cascade,
  name text not null
    constraint mailbox_folders_name_max_len check (char_length(name) between 1 and 1024),
  role text
    constraint mailbox_folders_role_allowed check (
      role is null or role in ('inbox', 'sent', 'drafts', 'trash', 'junk', 'archive', 'other')
    ),
  uidvalidity bigint
    constraint mailbox_folders_uidvalidity_nonneg check (uidvalidity is null or uidvalidity >= 0),
  uidnext bigint
    constraint mailbox_folders_uidnext_nonneg check (uidnext is null or uidnext >= 0),
  last_seen_uid bigint
    constraint mailbox_folders_last_seen_uid_nonneg check (last_seen_uid is null or last_seen_uid >= 0),
  highest_modseq bigint
    constraint mailbox_folders_highest_modseq_nonneg check (highest_modseq is null or highest_modseq >= 0),
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mailbox_folders_mailbox_name_uq unique (mailbox_id, name)
);
comment on table public.mailbox_folders is
  'Phase 3A: discovered IMAP folders + safe-to-expose sync cursors (uidvalidity/uidnext/last_seen_uid/highest_modseq). authenticated: SELECT only; the worker maintains the cursors.';

create index if not exists idx_mailbox_folders_mailbox_id on public.mailbox_folders (mailbox_id);
create index if not exists idx_mailbox_folders_workspace_id on public.mailbox_folders (workspace_id);

-- 1.3 mail_messages (METADATA ONLY — never any body/content) ------------------
create table if not exists public.mail_messages (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  mailbox_id uuid not null references public.mailboxes (id) on delete cascade,
  folder_id uuid not null references public.mailbox_folders (id) on delete cascade,
  uidvalidity bigint not null
    constraint mail_messages_uidvalidity_nonneg check (uidvalidity >= 0),
  uid bigint not null
    constraint mail_messages_uid_nonneg check (uid >= 0),
  message_id text
    constraint mail_messages_message_id_max_len check (message_id is null or char_length(message_id) <= 998),
  in_reply_to text
    constraint mail_messages_in_reply_to_max_len check (in_reply_to is null or char_length(in_reply_to) <= 998),
  references_header text,
  subject text
    constraint mail_messages_subject_max_len check (subject is null or char_length(subject) <= 2000),
  from_summary text
    constraint mail_messages_from_summary_max_len check (from_summary is null or char_length(from_summary) <= 2000),
  to_summary text
    constraint mail_messages_to_summary_max_len check (to_summary is null or char_length(to_summary) <= 4000),
  internal_date timestamptz,
  size_bytes bigint
    constraint mail_messages_size_nonneg check (size_bytes is null or size_bytes >= 0),
  flags text[] not null default array[]::text[],
  has_attachments boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Provider dedupe key: a message is identified by (folder, uidvalidity, uid).
  constraint mail_messages_folder_uid_uq unique (folder_id, uidvalidity, uid)
);
comment on table public.mail_messages is
  'Phase 3A: synchronized message METADATA ONLY (headers/summary/flags/size). NEVER stores the body or any content. Dedupe on (folder_id, uidvalidity, uid). authenticated: SELECT only.';
comment on column public.mail_messages.references_header is
  'The RFC 5322 References header value (kept as text; "references" is a reserved word so the column is references_header).';

create index if not exists idx_mail_messages_folder_id on public.mail_messages (folder_id);
create index if not exists idx_mail_messages_mailbox_id on public.mail_messages (mailbox_id);
create index if not exists idx_mail_messages_workspace_id on public.mail_messages (workspace_id);
create index if not exists idx_mail_messages_message_id on public.mail_messages (message_id);

-- 1.4 draft_mirrors ----------------------------------------------------------
create table if not exists public.draft_mirrors (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  draft_id uuid not null references public.drafts (id) on delete cascade,
  mailbox_id uuid not null references public.mailboxes (id) on delete cascade,
  remote_uid bigint
    constraint draft_mirrors_remote_uid_nonneg check (remote_uid is null or remote_uid >= 0),
  remote_uidvalidity bigint
    constraint draft_mirrors_remote_uidvalidity_nonneg check (remote_uidvalidity is null or remote_uidvalidity >= 0),
  mirrored_revision bigint
    constraint draft_mirrors_mirrored_revision_positive check (mirrored_revision is null or mirrored_revision > 0),
  status text not null default 'pending'
    constraint draft_mirrors_status_allowed check (status in ('pending', 'mirrored', 'stale', 'failed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- One mirror row per (draft, mailbox): idempotent draft->remote mapping.
  constraint draft_mirrors_draft_mailbox_uq unique (draft_id, mailbox_id)
);
comment on table public.draft_mirrors is
  'Phase 3A: maps a local draft to its mirrored remote IMAP copy (Drafts folder). Idempotent on (draft_id, mailbox_id). authenticated: SELECT only; the worker maintains it.';

create index if not exists idx_draft_mirrors_draft_id on public.draft_mirrors (draft_id);
create index if not exists idx_draft_mirrors_mailbox_id on public.draft_mirrors (mailbox_id);
create index if not exists idx_draft_mirrors_workspace_id on public.draft_mirrors (workspace_id);

-- 1.5 send_intents (IMMUTABLE confirmed send snapshot) -----------------------
create table if not exists public.send_intents (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  mailbox_id uuid not null references public.mailboxes (id) on delete cascade,
  draft_id uuid not null references public.drafts (id) on delete cascade,
  draft_revision bigint not null
    constraint send_intents_draft_revision_positive check (draft_revision > 0),
  sender text not null
    constraint send_intents_sender_format check (
      char_length(sender) between 3 and 320
      and sender ~ '^[^@[:space:]]+@[^@[:space:]]+$'
    ),
  recipients jsonb not null
    constraint send_intents_recipients_is_object check (jsonb_typeof(recipients) = 'object'),
  subject text not null default ''
    constraint send_intents_subject_max_len check (char_length(subject) <= 2000),
  html_hash text
    constraint send_intents_html_hash_format check (html_hash is null or html_hash ~ '^[a-f0-9]{64}$'),
  text_hash text
    constraint send_intents_text_hash_format check (text_hash is null or text_hash ~ '^[a-f0-9]{64}$'),
  attachment_manifest jsonb not null default '[]'::jsonb
    constraint send_intents_attachment_manifest_is_array check (jsonb_typeof(attachment_manifest) = 'array'),
  message_id text not null
    constraint send_intents_message_id_format check (message_id ~ '^<[^<>@[:space:]]+@[^<>@[:space:]]+>$'),
  idempotency_key text not null
    constraint send_intents_idempotency_key_uq unique
    constraint send_intents_idempotency_key_len check (char_length(idempotency_key) between 1 and 255),
  template_version_id uuid,
  signature_id uuid,
  contract_version integer not null default 1
    constraint send_intents_contract_version_positive check (contract_version > 0),
  confirmed_by uuid not null references public.users (id),
  confirmed_at timestamptz not null default now(),
  confirmation_proof text not null
    constraint send_intents_confirmation_proof_format check (confirmation_proof ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now()
);
comment on table public.send_intents is
  'Phase 3A: IMMUTABLE snapshot of a user-confirmed send. Written ONLY by create_send_intent (SECURITY DEFINER), which server-generates message_id + confirmation_proof + idempotency_key. A reject-update/delete trigger freezes every row. authenticated: SELECT only.';
comment on column public.send_intents.confirmation_proof is
  'Server-computed sha256 (hex) over the canonical snapshot (payload + confirmed_by + message_id + contract_version); binds the user approval to the exact bytes that will be sent.';

create index if not exists idx_send_intents_workspace_id on public.send_intents (workspace_id);
create index if not exists idx_send_intents_mailbox_id on public.send_intents (mailbox_id);
create index if not exists idx_send_intents_draft_id on public.send_intents (draft_id);

-- 1.6 send_attempts (outbound state machine) ---------------------------------
create table if not exists public.send_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  send_intent_id uuid not null references public.send_intents (id) on delete cascade,
  state text not null
    constraint send_attempts_state_allowed check (state in (
      'pending_confirmation', 'confirmed', 'queued', 'claimed',
      'smtp_in_progress', 'smtp_accepted', 'sent_copy_pending', 'completed',
      'failed_before_delivery', 'needs_human_review', 'cancelled'
    )),
  claimed_by text
    constraint send_attempts_claimed_by_max_len check (claimed_by is null or char_length(claimed_by) <= 255),
  claimed_at timestamptz,
  message_id text
    constraint send_attempts_message_id_max_len check (message_id is null or char_length(message_id) <= 998),
  smtp_response text
    constraint send_attempts_smtp_response_max_len check (smtp_response is null or char_length(smtp_response) <= 4000),
  evidence jsonb not null default '{}'::jsonb
    constraint send_attempts_evidence_is_object check (jsonb_typeof(evidence) = 'object'),
  version bigint not null default 1
    constraint send_attempts_version_positive check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.send_attempts is
  'Phase 3A: outbound state machine per send intent. Worker advances state under compare-and-set (version). A trigger rejects illegal transitions and version rollback; completed/needs_human_review/cancelled are terminal for the automated path. authenticated: SELECT only.';

create index if not exists idx_send_attempts_send_intent_id on public.send_attempts (send_intent_id);
create index if not exists idx_send_attempts_workspace_id on public.send_attempts (workspace_id);
create index if not exists idx_send_attempts_state on public.send_attempts (state);

-- 1.7 transport_audit (content-free append-only events) ----------------------
create table if not exists public.transport_audit (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  mailbox_id uuid references public.mailboxes (id) on delete set null,
  event_type text not null
    constraint transport_audit_event_type_max_len check (char_length(event_type) between 1 and 100),
  send_intent_id uuid references public.send_intents (id) on delete set null,
  send_attempt_id uuid references public.send_attempts (id) on delete set null,
  correlation_id text
    constraint transport_audit_correlation_id_max_len check (correlation_id is null or char_length(correlation_id) <= 255),
  message_id text
    constraint transport_audit_message_id_max_len check (message_id is null or char_length(message_id) <= 998),
  detail jsonb not null default '{}'::jsonb
    constraint transport_audit_detail_is_object check (jsonb_typeof(detail) = 'object'),
  created_at timestamptz not null default now()
);
comment on table public.transport_audit is
  'Phase 3A: content-free transport audit trail (event_type + correlation/message ids + small non-content detail). NEVER stores message bodies. Append-only. authenticated: SELECT within own workspace.';

create index if not exists idx_transport_audit_workspace_id on public.transport_audit (workspace_id);
create index if not exists idx_transport_audit_mailbox_id on public.transport_audit (mailbox_id);
create index if not exists idx_transport_audit_created_at on public.transport_audit (workspace_id, created_at desc);

-- ===========================================================================
-- 2. transport tables (PRIVATE — no anon/authenticated access whatsoever)
-- ===========================================================================

-- 2.1 transport.mailbox_credentials (encrypted secrets; NO plaintext column) --
create table if not exists transport.mailbox_credentials (
  id uuid primary key default gen_random_uuid(),
  mailbox_id uuid not null references public.mailboxes (id) on delete cascade,
  ciphertext bytea not null,
  nonce bytea not null,
  auth_tag bytea,
  algorithm text not null default 'aes-256-gcm'
    constraint mailbox_credentials_algorithm_max_len check (char_length(algorithm) <= 64),
  key_version integer not null default 1
    constraint mailbox_credentials_key_version_positive check (key_version > 0),
  aad text not null
    constraint mailbox_credentials_aad_max_len check (char_length(aad) between 1 and 512),
  created_at timestamptz not null default now(),
  rotated_at timestamptz,
  revoked_at timestamptz
);
comment on table transport.mailbox_credentials is
  'Phase 3A (PRIVATE): AEAD-encrypted IMAP/SMTP credential. Stores ciphertext/nonce/auth_tag/algorithm/key_version and the AAD binding (to workspace+mailbox); NEVER a plaintext column. Decryptable only by the worker holding the KMS key. Unreachable by the browser.';

create index if not exists idx_mailbox_credentials_mailbox_id on transport.mailbox_credentials (mailbox_id);
-- At most one ACTIVE (non-revoked) credential per mailbox.
create unique index if not exists uq_mailbox_credentials_active
  on transport.mailbox_credentials (mailbox_id)
  where revoked_at is null;

-- 2.2 transport.worker_claims (atomic lease rows) ----------------------------
create table if not exists transport.worker_claims (
  id uuid primary key default gen_random_uuid(),
  send_attempt_id uuid not null references public.send_attempts (id) on delete cascade,
  worker_id text not null
    constraint worker_claims_worker_id_max_len check (char_length(worker_id) between 1 and 255),
  lease_until timestamptz not null,
  heartbeat_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  -- One live claim per attempt (reconciliation deletes/expires it to re-claim).
  constraint worker_claims_send_attempt_uq unique (send_attempt_id)
);
comment on table transport.worker_claims is
  'Phase 3A (PRIVATE): atomic claim/lease per send_attempt for at-most-one-worker delivery. Unreachable by the browser.';

create index if not exists idx_worker_claims_worker_id on transport.worker_claims (worker_id);
create index if not exists idx_worker_claims_lease_until on transport.worker_claims (lease_until);

-- 2.3 transport.worker_heartbeats (liveness; NO message content) --------------
create table if not exists transport.worker_heartbeats (
  worker_id text primary key
    constraint worker_heartbeats_worker_id_max_len check (char_length(worker_id) between 1 and 255),
  last_seen timestamptz not null default now(),
  state text
    constraint worker_heartbeats_state_max_len check (state is null or char_length(state) <= 64),
  created_at timestamptz not null default now()
);
comment on table transport.worker_heartbeats is
  'Phase 3A (PRIVATE): worker liveness rows (worker_id/last_seen/state). NO message content. Unreachable by the browser.';

-- ===========================================================================
-- 3. Integrity trigger functions (SECURITY INVOKER, empty search_path)
-- ===========================================================================

-- 3.1 Generic updated_at touch (BEFORE UPDATE).
create or replace function public.phase3_touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
comment on function public.phase3_touch_updated_at() is
  'Phase 3A integrity: refresh updated_at on UPDATE.';

-- 3.2 A child row must live in the same workspace as its parent mailbox.
create or replace function public.phase3_check_mailbox_workspace()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_ws uuid;
begin
  select m.workspace_id into v_ws from public.mailboxes m where m.id = new.mailbox_id;
  if v_ws is null or v_ws is distinct from new.workspace_id then
    raise exception '%.workspace_id must match its mailbox''s workspace', tg_table_name
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase3_check_mailbox_workspace() is
  'Phase 3A integrity: a mailbox-child row (folder/message/mirror/intent/attempt-by-mailbox) cannot claim a workspace different from its parent mailbox.';

-- 3.3 A message must belong to a folder of the same mailbox + workspace.
create or replace function public.phase3_check_message_parent()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_ws uuid;
  v_mailbox uuid;
begin
  select f.workspace_id, f.mailbox_id into v_ws, v_mailbox
  from public.mailbox_folders f where f.id = new.folder_id;
  if v_ws is null
     or v_ws is distinct from new.workspace_id
     or v_mailbox is distinct from new.mailbox_id then
    raise exception 'mail_messages must match its folder''s workspace and mailbox'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase3_check_message_parent() is
  'Phase 3A integrity: a mail_messages row must reference a folder of the same mailbox and workspace.';

-- 3.4 send_attempts must inherit their intent's workspace.
create or replace function public.phase3_check_attempt_parent()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_ws uuid;
begin
  select i.workspace_id into v_ws from public.send_intents i where i.id = new.send_intent_id;
  if v_ws is null or v_ws is distinct from new.workspace_id then
    raise exception 'send_attempts.workspace_id must match its send_intent''s workspace'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase3_check_attempt_parent() is
  'Phase 3A integrity: a send_attempts row must inherit the workspace of its send_intent.';

-- 3.5 send_intents are frozen after insert (UPDATE always raises).
--     Deliberately BEFORE UPDATE only — NOT delete: a raise-on-DELETE trigger
--     would abort legitimate FK ON DELETE CASCADE from workspaces/mailboxes/
--     drafts. Deletion by the browser is already impossible (SELECT-only grant,
--     no DELETE policy); this trigger closes the remaining mutation vector.
create or replace function public.phase3_send_intents_immutable()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'send_intents rows are immutable' using errcode = '23514';
end;
$$;
comment on function public.phase3_send_intents_immutable() is
  'Phase 3A integrity: send_intents are a confirmed, immutable snapshot — UPDATE always raises. No DELETE trigger, so FK ON DELETE CASCADE (workspace/mailbox/draft removal) still cleans them up; direct deletion by authenticated is already blocked by the SELECT-only grant.';

-- (transport_audit append-only is enforced purely by privileges: authenticated
--  gets SELECT only and the worker gets SELECT+INSERT — neither can UPDATE or
--  DELETE. No raise-on-mutation trigger is used, because the table's ON DELETE
--  SET NULL / CASCADE foreign keys must remain free to run.)

-- 3.7 Allowed send_attempts transitions (pure function).
create or replace function public.phase3_send_attempt_transition_ok(p_from text, p_to text)
returns boolean
language sql
immutable
security invoker
set search_path = ''
as $$
  select case
    when p_from = p_to then true                                   -- field-only update
    when p_from = 'pending_confirmation'   and p_to in ('confirmed', 'cancelled') then true
    when p_from = 'confirmed'              and p_to in ('queued', 'cancelled') then true
    when p_from = 'queued'                 and p_to in ('claimed', 'cancelled') then true
    when p_from = 'claimed'                and p_to in ('smtp_in_progress', 'failed_before_delivery', 'needs_human_review', 'cancelled') then true
    when p_from = 'smtp_in_progress'       and p_to in ('smtp_accepted', 'failed_before_delivery', 'needs_human_review') then true
    when p_from = 'smtp_accepted'          and p_to in ('sent_copy_pending', 'completed', 'needs_human_review') then true
    when p_from = 'sent_copy_pending'      and p_to in ('completed', 'needs_human_review') then true
    when p_from = 'failed_before_delivery' and p_to in ('queued', 'needs_human_review', 'cancelled') then true
    else false                                                     -- completed/needs_human_review/cancelled are terminal
  end;
$$;
comment on function public.phase3_send_attempt_transition_ok(text, text) is
  'Phase 3A: authoritative send_attempts transition table. completed/needs_human_review/cancelled are terminal for the automated path.';

-- 3.8 send_attempts BEFORE UPDATE guard: legal transition, no version rollback,
--     immutable workspace/intent, refresh updated_at.
create or replace function public.phase3_send_attempts_before_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.workspace_id is distinct from old.workspace_id then
    raise exception 'send_attempts.workspace_id is immutable' using errcode = '23514';
  end if;
  if new.send_intent_id is distinct from old.send_intent_id then
    raise exception 'send_attempts.send_intent_id is immutable' using errcode = '23514';
  end if;
  if not public.phase3_send_attempt_transition_ok(old.state, new.state) then
    raise exception 'illegal send_attempts transition % -> %', old.state, new.state
      using errcode = '23514';
  end if;
  if new.version < old.version then
    raise exception 'send_attempts.version may never decrease (% -> %)', old.version, new.version
      using errcode = '23514';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
comment on function public.phase3_send_attempts_before_update() is
  'Phase 3A integrity: enforces the transition table, forbids version rollback and workspace/intent mutation, refreshes updated_at.';

-- Trigger functions are internal machinery: nobody calls them directly.
revoke execute on function
  public.phase3_touch_updated_at(),
  public.phase3_check_mailbox_workspace(),
  public.phase3_check_message_parent(),
  public.phase3_check_attempt_parent(),
  public.phase3_send_intents_immutable(),
  public.phase3_send_attempt_transition_ok(text, text),
  public.phase3_send_attempts_before_update()
from public, anon, authenticated;
grant execute on function public.phase3_send_attempt_transition_ok(text, text) to service_role;

-- ===========================================================================
-- 4. Triggers
-- ===========================================================================

-- mailboxes: immutable workspace_id + created_by, touch updated_at.
create or replace trigger trg_mailboxes_forbid_workspace_change
  before update on public.mailboxes
  for each row execute function public.phase2_forbid_workspace_change();
create or replace trigger trg_mailboxes_forbid_created_by_change
  before update on public.mailboxes
  for each row execute function public.phase2_forbid_created_by_change();
create or replace trigger trg_mailboxes_touch
  before update on public.mailboxes
  for each row execute function public.phase3_touch_updated_at();

-- mailbox_folders: parent-workspace match (insert+update), touch.
create or replace trigger trg_mailbox_folders_check_parent
  before insert or update on public.mailbox_folders
  for each row execute function public.phase3_check_mailbox_workspace();
create or replace trigger trg_mailbox_folders_touch
  before update on public.mailbox_folders
  for each row execute function public.phase3_touch_updated_at();

-- mail_messages: folder/mailbox/workspace match (insert+update), touch.
create or replace trigger trg_mail_messages_check_parent
  before insert or update on public.mail_messages
  for each row execute function public.phase3_check_message_parent();
create or replace trigger trg_mail_messages_touch
  before update on public.mail_messages
  for each row execute function public.phase3_touch_updated_at();

-- draft_mirrors: parent-mailbox workspace match (insert+update), touch.
create or replace trigger trg_draft_mirrors_check_parent
  before insert or update on public.draft_mirrors
  for each row execute function public.phase3_check_mailbox_workspace();
create or replace trigger trg_draft_mirrors_touch
  before update on public.draft_mirrors
  for each row execute function public.phase3_touch_updated_at();

-- send_intents: parent-mailbox workspace match on insert; UPDATE-frozen after.
create or replace trigger trg_send_intents_check_parent
  before insert on public.send_intents
  for each row execute function public.phase3_check_mailbox_workspace();
create or replace trigger trg_send_intents_immutable_update
  before update on public.send_intents
  for each row execute function public.phase3_send_intents_immutable();

-- send_attempts: parent-intent workspace match on insert; guarded on update.
create or replace trigger trg_send_attempts_check_parent
  before insert on public.send_attempts
  for each row execute function public.phase3_check_attempt_parent();
create or replace trigger trg_send_attempts_before_update
  before update on public.send_attempts
  for each row execute function public.phase3_send_attempts_before_update();

-- ===========================================================================
-- 5. RPCs (SECURITY DEFINER; empty search_path) — the only browser write path
-- ===========================================================================

-- 5.1 create_send_intent -----------------------------------------------------
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
  if p_sender is null or p_sender !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
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

  -- Idempotency: a client-supplied key makes retries safe; absent, generate one.
  v_idem := coalesce(nullif(p_idempotency_key, ''), gen_random_uuid()::text);
  if char_length(v_idem) > 255 then
    raise exception 'idempotency_key must be at most 255 characters' using errcode = '22023';
  end if;
  select * into v_existing from public.send_intents where idempotency_key = v_idem;
  if found then
    -- Only surface it to a member of its workspace; otherwise behave as "not found".
    if not public.is_workspace_member(v_existing.workspace_id) then
      raise exception 'mailbox not found or access denied' using errcode = 'P0002';
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

  -- Server-generate the RFC 5322 Message-ID from the sender domain.
  v_domain := nullif(split_part(p_sender, '@', 2), '');
  if v_domain is null then
    v_domain := 'mail.local';
  end if;
  v_message_id := '<' || gen_random_uuid()::text || '@' || v_domain || '>';

  -- Server-compute the confirmation proof over the canonical snapshot. jsonb
  -- normalizes key order, so the digest is deterministic for identical input.
  v_canonical := jsonb_build_object(
    'workspace_id', p_workspace_id,
    'mailbox_id', p_mailbox_id,
    'draft_id', p_draft_id,
    'draft_revision', p_draft_revision,
    'sender', p_sender,
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
    confirmed_by, confirmation_proof
  ) values (
    p_workspace_id, p_mailbox_id, p_draft_id, p_draft_revision, p_sender, v_recipients,
    v_subject, p_html_hash, p_text_hash, v_manifest, v_message_id,
    v_idem, p_template_version_id, p_signature_id, v_contract,
    v_uid, v_proof
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
  'Phase 3A RPC (SECURITY DEFINER): the ONLY write path for send_intents. Verifies membership + mailbox/draft ownership + kill switch/enabled, server-generates message_id, idempotency_key and confirmation_proof, inserts the immutable intent, seeds a send_attempt in state=confirmed, and appends a content-free audit event. Idempotent on idempotency_key.';

-- 5.2 request_mailbox_sync ---------------------------------------------------
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

  -- No IMAP here: just record the request; the worker polls and does the work.
  insert into public.transport_audit (workspace_id, mailbox_id, event_type)
  values (v_mailbox.workspace_id, v_mailbox.id, 'mailbox_sync_requested');

  return jsonb_build_object(
    'mailbox_id', v_mailbox.id,
    'status', 'requested',
    'requested_at', now()
  );
end;
$$;
comment on function public.request_mailbox_sync(uuid, uuid) is
  'Phase 3A RPC (SECURITY DEFINER): a member asks the worker to sync a mailbox. Validates membership + ownership + enabled/kill-switch, records a content-free audit event, and returns. Performs NO IMAP in SQL; the worker enqueues and executes the actual sync.';

-- RPC execution grants: authenticated (+ service_role) only; never anon/public.
revoke execute on function
  public.create_send_intent(uuid, uuid, uuid, bigint, text, jsonb, text, text, text, jsonb, uuid, uuid, integer, text)
  from public, anon;
revoke execute on function public.request_mailbox_sync(uuid, uuid) from public, anon;

grant execute on function
  public.create_send_intent(uuid, uuid, uuid, bigint, text, jsonb, text, text, text, jsonb, uuid, uuid, integer, text)
  to authenticated, service_role;
grant execute on function public.request_mailbox_sync(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 6. Grants (revoke-then-grant defeats any inherited / default-ACL privilege)
-- ===========================================================================

-- 6.1 public transport tables: authenticated SELECT only; anon nothing.
revoke all on table
  public.mailboxes, public.mailbox_folders, public.mail_messages,
  public.draft_mirrors, public.send_intents, public.send_attempts,
  public.transport_audit
from public, anon, authenticated;

grant select on table
  public.mailboxes, public.mailbox_folders, public.mail_messages,
  public.draft_mirrors, public.send_intents, public.send_attempts,
  public.transport_audit
to authenticated;

grant all on table
  public.mailboxes, public.mailbox_folders, public.mail_messages,
  public.draft_mirrors, public.send_intents, public.send_attempts,
  public.transport_audit
to service_role;

-- The worker's narrow, explicit write surface on the public transport tables
-- (it never gets broad public write). Reads config, maintains sync metadata +
-- mirrors, advances the outbound state machine, appends audit events.
grant select on table public.mailboxes to transport_worker;
grant select, insert, update, delete on table public.mailbox_folders to transport_worker;
grant select, insert, update, delete on table public.mail_messages to transport_worker;
grant select, insert, update, delete on table public.draft_mirrors to transport_worker;
grant select on table public.send_intents to transport_worker;
grant select, update on table public.send_attempts to transport_worker;
grant select, insert on table public.transport_audit to transport_worker;

-- 6.2 private transport.* tables: anon/authenticated get NOTHING; only the
--     worker (narrow DML) and service_role (operational) may touch them.
revoke all on table
  transport.mailbox_credentials, transport.worker_claims, transport.worker_heartbeats
from public, anon, authenticated;

grant select on table transport.mailbox_credentials to transport_worker;
grant select, insert, update, delete on table transport.worker_claims to transport_worker;
grant select, insert, update, delete on table transport.worker_heartbeats to transport_worker;

grant all on table
  transport.mailbox_credentials, transport.worker_claims, transport.worker_heartbeats
to service_role;

-- ===========================================================================
-- 7. Row Level Security
-- ===========================================================================

-- 7.1 public transport tables: RLS on; members read within their workspace.
alter table public.mailboxes enable row level security;
alter table public.mailbox_folders enable row level security;
alter table public.mail_messages enable row level security;
alter table public.draft_mirrors enable row level security;
alter table public.send_intents enable row level security;
alter table public.send_attempts enable row level security;
alter table public.transport_audit enable row level security;

drop policy if exists mailboxes_select_members on public.mailboxes;
create policy mailboxes_select_members on public.mailboxes
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy mailboxes_select_members on public.mailboxes is
  'Phase 3A: workspace members read mailbox metadata (no secrets here).';

drop policy if exists mailbox_folders_select_members on public.mailbox_folders;
create policy mailbox_folders_select_members on public.mailbox_folders
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy mailbox_folders_select_members on public.mailbox_folders is
  'Phase 3A: workspace members read folder metadata + cursors.';

drop policy if exists mail_messages_select_members on public.mail_messages;
create policy mail_messages_select_members on public.mail_messages
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy mail_messages_select_members on public.mail_messages is
  'Phase 3A: workspace members read message metadata (never any body).';

drop policy if exists draft_mirrors_select_members on public.draft_mirrors;
create policy draft_mirrors_select_members on public.draft_mirrors
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy draft_mirrors_select_members on public.draft_mirrors is
  'Phase 3A: workspace members read draft-mirror mapping.';

drop policy if exists send_intents_select_members on public.send_intents;
create policy send_intents_select_members on public.send_intents
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy send_intents_select_members on public.send_intents is
  'Phase 3A: workspace members read confirmed send intents.';

drop policy if exists send_attempts_select_members on public.send_attempts;
create policy send_attempts_select_members on public.send_attempts
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy send_attempts_select_members on public.send_attempts is
  'Phase 3A: workspace members read outbound state.';

drop policy if exists transport_audit_select_members on public.transport_audit;
create policy transport_audit_select_members on public.transport_audit
  for select to authenticated using (public.is_workspace_member(workspace_id));
comment on policy transport_audit_select_members on public.transport_audit is
  'Phase 3A: workspace members read their own workspace''s content-free audit trail.';

-- 7.2 private transport tables: RLS on with NO policies (defence in depth). The
--     only roles that can reach them (transport_worker, service_role) are
--     BYPASSRLS; anon/authenticated have no schema USAGE, so this is belt AND
--     suspenders — even a mistaken future grant would still expose zero rows.
alter table transport.mailbox_credentials enable row level security;
alter table transport.worker_claims enable row level security;
alter table transport.worker_heartbeats enable row level security;

-- ============================================================================
-- End of migration 20260713100000_transport_foundation.sql
-- ============================================================================
