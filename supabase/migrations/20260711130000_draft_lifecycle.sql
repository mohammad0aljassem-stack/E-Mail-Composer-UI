-- ============================================================================
-- Phase 2 — Draft lifecycle, versions, templates, signatures, attachments
-- Migration: 20260711130000_draft_lifecycle.sql
--
-- Strictly ADDITIVE on top of production migration 20260709182252. It only
-- creates new objects (tables, triggers, functions, policies, one storage
-- bucket row + storage policies) and never alters or drops existing ones.
-- Idempotency guards (IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF
-- EXISTS / ON CONFLICT DO NOTHING / guarded DO blocks) make a re-run safe.
--
-- Canonical names, limits and error codes come from src/lib/phase2/contracts.ts:
--   bucket "draft-attachments", 10 MiB/file, 10 attachments/draft,
--   25 MiB/draft total, MIME allowlist (application/pdf, image/png,
--   image/jpeg, text/plain), revision-conflict SQLSTATE 'P0409'.
--
-- Error-code conventions used by the RPCs and integrity triggers:
--   P0409 revision conflict                 22023 invalid argument value
--   P0002 row not found / not accessible    54000 attachment count/size limit
--   42501 authentication required           55000 storage object precondition
--   23514 integrity-trigger violation (mirrors a CHECK violation)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

-- 1.1 drafts ------------------------------------------------------------------
create table if not exists public.drafts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  subject text not null default ''
    constraint drafts_subject_max_len check (char_length(subject) <= 500),
  body_json jsonb not null
    constraint drafts_body_json_is_doc check (
      jsonb_typeof(body_json) = 'object'
      and body_json ->> 'type' = 'doc'
      and octet_length(body_json::text) <= 1048576
    ),
  status text not null default 'draft'
    constraint drafts_status_allowed check (status in ('draft', 'archived')),
  revision bigint not null default 1
    constraint drafts_revision_positive check (revision > 0),
  created_by uuid not null references public.users (id),
  updated_by uuid not null references public.users (id),
  last_autosaved_at timestamptz,
  archived_at timestamptz,
  last_template_version_id uuid,
  last_signature_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.drafts is
  'Phase 2: workspace-scoped email drafts with optimistic-concurrency revision counter.';
comment on column public.drafts.body_json is
  'Canonical TipTap-style document (root {"type":"doc",...}); max 1 MiB serialized.';
comment on column public.drafts.revision is
  'Optimistic concurrency token; save/restore RPCs raise SQLSTATE P0409 on mismatch.';
comment on column public.drafts.last_template_version_id is
  'Loose pointer to the template version last applied (no FK by design; informational).';
comment on column public.drafts.last_signature_id is
  'Loose pointer to the signature last applied (no FK by design; informational).';

create index if not exists idx_drafts_workspace_id on public.drafts (workspace_id);
create index if not exists idx_drafts_workspace_updated_at on public.drafts (workspace_id, updated_at desc);
create index if not exists idx_drafts_workspace_status on public.drafts (workspace_id, status);
create index if not exists idx_drafts_created_by on public.drafts (created_by);
create index if not exists idx_drafts_updated_by on public.drafts (updated_by);

-- 1.2 draft_versions ----------------------------------------------------------
create table if not exists public.draft_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  draft_id uuid not null references public.drafts (id) on delete cascade,
  version_no bigint not null
    constraint draft_versions_version_no_positive check (version_no > 0),
  source_revision bigint not null
    constraint draft_versions_source_revision_positive check (source_revision > 0),
  subject text not null
    constraint draft_versions_subject_max_len check (char_length(subject) <= 500),
  body_json jsonb not null
    constraint draft_versions_body_json_is_doc check (
      jsonb_typeof(body_json) = 'object'
      and body_json ->> 'type' = 'doc'
      and octet_length(body_json::text) <= 1048576
    ),
  reason text not null
    constraint draft_versions_reason_allowed check (reason in (
      'initial', 'autosave_checkpoint', 'manual_checkpoint',
      'before_template', 'after_template',
      'before_signature', 'after_signature', 'restore'
    )),
  created_by uuid not null references public.users (id),
  created_at timestamptz not null default now(),
  constraint draft_versions_draft_version_uq unique (draft_id, version_no)
);

comment on table public.draft_versions is
  'Phase 2: immutable, append-only snapshots of draft content (version history).';
comment on column public.draft_versions.source_revision is
  'drafts.revision at (or right after) the moment the snapshot was taken.';

create index if not exists idx_draft_versions_draft_version on public.draft_versions (draft_id, version_no desc);
create index if not exists idx_draft_versions_workspace_id on public.draft_versions (workspace_id);

-- 1.3 draft_templates ---------------------------------------------------------
create table if not exists public.draft_templates (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  name text not null
    constraint draft_templates_name_max_len check (char_length(name) <= 200),
  description text,
  archived_at timestamptz,
  created_by uuid not null references public.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.draft_templates is
  'Phase 2: workspace-shared email templates (versioned via draft_template_versions).';

create index if not exists idx_draft_templates_workspace_id on public.draft_templates (workspace_id);

-- 1.4 draft_template_versions -------------------------------------------------
create table if not exists public.draft_template_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  template_id uuid not null references public.draft_templates (id) on delete cascade,
  version_no bigint not null
    constraint draft_template_versions_version_no_positive check (version_no > 0),
  subject_template text not null default ''
    constraint draft_template_versions_subject_max_len check (char_length(subject_template) <= 500),
  body_template_json jsonb not null
    constraint draft_template_versions_body_is_doc check (
      jsonb_typeof(body_template_json) = 'object'
      and body_template_json ->> 'type' = 'doc'
    ),
  variable_schema jsonb not null default '[]'::jsonb
    constraint draft_template_versions_variable_schema_is_array check (jsonb_typeof(variable_schema) = 'array'),
  created_by uuid not null references public.users (id),
  created_at timestamptz not null default now(),
  constraint draft_template_versions_template_version_uq unique (template_id, version_no)
);

comment on table public.draft_template_versions is
  'Phase 2: immutable, append-only template versions (content + variable schema).';

create index if not exists idx_draft_template_versions_template_version
  on public.draft_template_versions (template_id, version_no desc);
create index if not exists idx_draft_template_versions_workspace_id
  on public.draft_template_versions (workspace_id);

-- 1.5 signatures ---------------------------------------------------------------
create table if not exists public.signatures (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  owner_user_id uuid not null references public.users (id) on delete cascade,
  name text not null
    constraint signatures_name_max_len check (char_length(name) <= 200),
  body_json jsonb not null
    constraint signatures_body_json_is_doc check (
      jsonb_typeof(body_json) = 'object'
      and body_json ->> 'type' = 'doc'
      and octet_length(body_json::text) <= 1048576
    ),
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.signatures is
  'Phase 2: per-user email signatures. Private to their owner (RLS), one default per user+workspace.';

-- At most one default signature per (workspace, owner).
create unique index if not exists uq_signatures_default_per_owner
  on public.signatures (workspace_id, owner_user_id)
  where is_default;
comment on index public.uq_signatures_default_per_owner is
  'Enforces a single default signature per user per workspace.';

create index if not exists idx_signatures_workspace_id on public.signatures (workspace_id);
create index if not exists idx_signatures_owner_user_id on public.signatures (owner_user_id);

-- 1.6 draft_attachments ---------------------------------------------------------
create table if not exists public.draft_attachments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  draft_id uuid not null references public.drafts (id) on delete cascade,
  storage_bucket text not null default 'draft-attachments'
    constraint draft_attachments_bucket_fixed check (storage_bucket = 'draft-attachments'),
  storage_path text not null
    constraint draft_attachments_storage_path_uq unique,
  original_filename text not null
    constraint draft_attachments_original_filename_max_len check (char_length(original_filename) <= 255),
  safe_filename text not null
    constraint draft_attachments_safe_filename_format check (safe_filename ~ '^[A-Za-z0-9._-]{1,200}$'),
  mime_type text not null
    constraint draft_attachments_mime_allowlist check (mime_type in (
      'application/pdf', 'image/png', 'image/jpeg', 'text/plain'
    )),
  size_bytes bigint not null
    constraint draft_attachments_size_range check (size_bytes > 0 and size_bytes <= 10485760),
  sha256 text
    constraint draft_attachments_sha256_format check (sha256 is null or sha256 ~ '^[a-f0-9]{64}$'),
  status text not null default 'pending'
    constraint draft_attachments_status_allowed check (status in ('pending', 'ready', 'failed', 'deleted')),
  created_by uuid not null references public.users (id),
  verified_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  -- Deterministic object key: <workspace>/<draft>/<attachment>/<safe filename>.
  -- Makes cross-workspace path forgery structurally impossible.
  constraint draft_attachments_path_formula check (
    storage_path = workspace_id::text || '/' || draft_id::text || '/' || id::text || '/' || safe_filename
  )
);

comment on table public.draft_attachments is
  'Phase 2: attachment metadata rows; binary lives in storage bucket draft-attachments under a constraint-enforced deterministic path.';
comment on column public.draft_attachments.storage_path is
  'Object key in the draft-attachments bucket; must equal workspace/draft/attachment/safe_filename (CHECK enforced).';
comment on column public.draft_attachments.status is
  'pending -> ready (finalize_attachment) | failed; deleted only after the storage object is gone.';

create index if not exists idx_draft_attachments_draft_id on public.draft_attachments (draft_id);
create index if not exists idx_draft_attachments_workspace_id on public.draft_attachments (workspace_id);
create index if not exists idx_draft_attachments_draft_status on public.draft_attachments (draft_id, status);

-- ---------------------------------------------------------------------------
-- 2. Integrity trigger functions (SECURITY INVOKER, empty search_path)
-- ---------------------------------------------------------------------------

create or replace function public.phase2_forbid_workspace_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.workspace_id is distinct from old.workspace_id then
    raise exception 'workspace_id is immutable on %', tg_table_name
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase2_forbid_workspace_change() is
  'Phase 2 integrity: rows can never move between workspaces.';

create or replace function public.phase2_forbid_created_by_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.created_by is distinct from old.created_by then
    raise exception 'created_by is immutable on %', tg_table_name
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase2_forbid_created_by_change() is
  'Phase 2 integrity: authorship cannot be rewritten.';

create or replace function public.phase2_forbid_owner_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.owner_user_id is distinct from old.owner_user_id then
    raise exception 'owner_user_id is immutable on %', tg_table_name
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase2_forbid_owner_change() is
  'Phase 2 integrity: signature ownership cannot be transferred.';

create or replace function public.phase2_version_rows_immutable()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception '% rows are immutable', tg_table_name
    using errcode = '23514';
end;
$$;
comment on function public.phase2_version_rows_immutable() is
  'Phase 2 integrity: version history rows are append-only (UPDATE always raises). FK ON DELETE CASCADE still works because referential actions do not fire this UPDATE trigger.';

create or replace function public.phase2_drafts_before_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.revision < old.revision then
    raise exception 'drafts.revision may never decrease (% -> %)', old.revision, new.revision
      using errcode = '23514';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
comment on function public.phase2_drafts_before_update() is
  'Phase 2 integrity: keeps drafts.updated_at fresh and forbids revision rollback.';

create or replace function public.phase2_draft_versions_check_parent()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_workspace uuid;
begin
  select d.workspace_id into v_parent_workspace
  from public.drafts d
  where d.id = new.draft_id;

  if v_parent_workspace is null or v_parent_workspace is distinct from new.workspace_id then
    raise exception 'draft_versions.workspace_id must match the parent draft''s workspace'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
comment on function public.phase2_draft_versions_check_parent() is
  'Phase 2 integrity: a version snapshot must live in the same workspace as its draft. Runs as invoker; drafts RLS makes invisible parents look absent, which also raises.';

create or replace function public.phase2_attachments_before_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status = 'ready' and old.status is distinct from 'ready' then
    if new.verified_at is null then
      raise exception 'attachment cannot become ready without verified_at'
        using errcode = '23514';
    end if;
    -- Invoker-rights existence probe. The storage.objects SELECT policy lets
    -- workspace members read their own workspace prefix, so a legitimate
    -- finalize sees the object; anyone else (or a missing object) fails here.
    if not exists (
      select 1 from storage.objects o
      where o.bucket_id = 'draft-attachments'
        and o.name = new.storage_path
    ) then
      raise exception 'attachment cannot become ready: storage object % not found', new.storage_path
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
comment on function public.phase2_attachments_before_update() is
  'Phase 2 integrity: status=ready requires verified_at and a real storage object at storage_path.';

-- Trigger functions are internal machinery: nobody calls them directly.
revoke execute on function
  public.phase2_forbid_workspace_change(),
  public.phase2_forbid_created_by_change(),
  public.phase2_forbid_owner_change(),
  public.phase2_version_rows_immutable(),
  public.phase2_drafts_before_update(),
  public.phase2_draft_versions_check_parent(),
  public.phase2_attachments_before_update()
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------

create or replace trigger trg_drafts_forbid_workspace_change
  before update on public.drafts
  for each row execute function public.phase2_forbid_workspace_change();
comment on trigger trg_drafts_forbid_workspace_change on public.drafts is
  'Phase 2: workspace_id immutable.';

create or replace trigger trg_drafts_forbid_created_by_change
  before update on public.drafts
  for each row execute function public.phase2_forbid_created_by_change();
comment on trigger trg_drafts_forbid_created_by_change on public.drafts is
  'Phase 2: created_by immutable.';

create or replace trigger trg_drafts_touch
  before update on public.drafts
  for each row execute function public.phase2_drafts_before_update();
comment on trigger trg_drafts_touch on public.drafts is
  'Phase 2: refresh updated_at, forbid revision decrease.';

create or replace trigger trg_draft_versions_immutable
  before update on public.draft_versions
  for each row execute function public.phase2_version_rows_immutable();
comment on trigger trg_draft_versions_immutable on public.draft_versions is
  'Phase 2: version snapshots are append-only.';

create or replace trigger trg_draft_versions_check_parent
  before insert on public.draft_versions
  for each row execute function public.phase2_draft_versions_check_parent();
comment on trigger trg_draft_versions_check_parent on public.draft_versions is
  'Phase 2: workspace_id must match the parent draft.';

create or replace trigger trg_draft_templates_forbid_workspace_change
  before update on public.draft_templates
  for each row execute function public.phase2_forbid_workspace_change();
comment on trigger trg_draft_templates_forbid_workspace_change on public.draft_templates is
  'Phase 2: workspace_id immutable.';

create or replace trigger trg_draft_templates_forbid_created_by_change
  before update on public.draft_templates
  for each row execute function public.phase2_forbid_created_by_change();
comment on trigger trg_draft_templates_forbid_created_by_change on public.draft_templates is
  'Phase 2: created_by immutable.';

create or replace trigger trg_draft_template_versions_immutable
  before update on public.draft_template_versions
  for each row execute function public.phase2_version_rows_immutable();
comment on trigger trg_draft_template_versions_immutable on public.draft_template_versions is
  'Phase 2: template versions are append-only.';

create or replace trigger trg_signatures_forbid_workspace_change
  before update on public.signatures
  for each row execute function public.phase2_forbid_workspace_change();
comment on trigger trg_signatures_forbid_workspace_change on public.signatures is
  'Phase 2: workspace_id immutable.';

create or replace trigger trg_signatures_forbid_owner_change
  before update on public.signatures
  for each row execute function public.phase2_forbid_owner_change();
comment on trigger trg_signatures_forbid_owner_change on public.signatures is
  'Phase 2: owner_user_id immutable.';

create or replace trigger trg_draft_attachments_forbid_workspace_change
  before update on public.draft_attachments
  for each row execute function public.phase2_forbid_workspace_change();
comment on trigger trg_draft_attachments_forbid_workspace_change on public.draft_attachments is
  'Phase 2: workspace_id immutable.';

create or replace trigger trg_draft_attachments_forbid_created_by_change
  before update on public.draft_attachments
  for each row execute function public.phase2_forbid_created_by_change();
comment on trigger trg_draft_attachments_forbid_created_by_change on public.draft_attachments is
  'Phase 2: created_by immutable.';

create or replace trigger trg_draft_attachments_guard_ready
  before update on public.draft_attachments
  for each row execute function public.phase2_attachments_before_update();
comment on trigger trg_draft_attachments_guard_ready on public.draft_attachments is
  'Phase 2: status=ready requires verification + existing storage object.';

-- ---------------------------------------------------------------------------
-- 4. RPCs (SECURITY INVOKER, empty search_path)
-- ---------------------------------------------------------------------------

-- 4.1 create_draft -------------------------------------------------------------
create or replace function public.create_draft(
  p_workspace_id uuid,
  p_subject text,
  p_body_json jsonb
) returns public.drafts
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not public.is_workspace_member(p_workspace_id) then
    raise exception 'workspace not found or access denied' using errcode = 'P0002';
  end if;

  insert into public.drafts (workspace_id, subject, body_json, created_by, updated_by)
  values (p_workspace_id, coalesce(p_subject, ''), p_body_json, v_uid, v_uid)
  returning * into v_draft;

  insert into public.draft_versions
    (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
  values
    (v_draft.workspace_id, v_draft.id, 1, v_draft.revision, v_draft.subject, v_draft.body_json, 'initial', v_uid);

  return v_draft;
end;
$$;
comment on function public.create_draft(uuid, text, jsonb) is
  'Phase 2 RPC: atomically create a draft (revision 1) plus its ''initial'' version snapshot.';

-- 4.2 save_draft ---------------------------------------------------------------
create or replace function public.save_draft(
  p_draft_id uuid,
  p_expected_revision bigint,
  p_subject text,
  p_body_json jsonb,
  p_save_reason text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
  v_subject text := coalesce(p_subject, '');
  v_last_version_at timestamptz;
  v_version_created boolean := false;
  v_version_reason text;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_save_reason is null
     or p_save_reason not in ('autosave', 'manual_checkpoint', 'after_template', 'after_signature') then
    raise exception 'invalid save reason: %', coalesce(p_save_reason, '<null>')
      using errcode = '22023';
  end if;

  -- RLS hides rows outside the caller's workspaces, so "not found" doubles as
  -- the authorization answer without leaking existence.
  select * into v_draft
  from public.drafts
  where id = p_draft_id
  for update;
  if not found then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;

  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409';
  end if;

  -- Identical content: report the current state, change nothing.
  if v_draft.subject = v_subject and v_draft.body_json = p_body_json then
    return jsonb_build_object(
      'revision', v_draft.revision,
      'updated_at', v_draft.updated_at,
      'last_autosaved_at', v_draft.last_autosaved_at,
      'version_created', false
    );
  end if;

  update public.drafts
  set subject = v_subject,
      body_json = p_body_json,
      revision = revision + 1,
      updated_by = v_uid,
      updated_at = now(),
      last_autosaved_at = now()
  where id = p_draft_id
  returning * into v_draft;

  if p_save_reason = 'autosave' then
    -- Autosaves only checkpoint when the newest version is older than the
    -- shared AUTOSAVE_CHECKPOINT_INTERVAL_MINUTES (10) policy window.
    select created_at into v_last_version_at
    from public.draft_versions
    where draft_id = p_draft_id
    order by version_no desc
    limit 1;
    if v_last_version_at is null or v_last_version_at < now() - interval '10 minutes' then
      v_version_reason := 'autosave_checkpoint';
    end if;
  else
    v_version_reason := p_save_reason; -- manual_checkpoint / after_template / after_signature
  end if;

  if v_version_reason is not null then
    insert into public.draft_versions
      (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
    select v_draft.workspace_id, v_draft.id,
           coalesce(max(dv.version_no), 0) + 1,
           v_draft.revision, v_draft.subject, v_draft.body_json, v_version_reason, v_uid
    from public.draft_versions dv
    where dv.draft_id = p_draft_id;
    v_version_created := true;
  end if;

  return jsonb_build_object(
    'revision', v_draft.revision,
    'updated_at', v_draft.updated_at,
    'last_autosaved_at', v_draft.last_autosaved_at,
    'version_created', v_version_created
  );
end;
$$;
comment on function public.save_draft(uuid, bigint, text, jsonb, text) is
  'Phase 2 RPC: optimistic-concurrency save (P0409 on stale revision); no-op on identical content; version policy: autosave checkpoints at most every 10 minutes, explicit reasons always checkpoint.';

-- 4.3 checkpoint_draft -----------------------------------------------------------
create or replace function public.checkpoint_draft(
  p_draft_id uuid,
  p_expected_revision bigint,
  p_reason text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
  v_latest public.draft_versions;
  v_next_no bigint;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_reason is null
     or p_reason not in ('manual_checkpoint', 'before_template', 'before_signature') then
    raise exception 'invalid checkpoint reason: %', coalesce(p_reason, '<null>')
      using errcode = '22023';
  end if;

  select * into v_draft
  from public.drafts
  where id = p_draft_id
  for update;
  if not found then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409';
  end if;

  select * into v_latest
  from public.draft_versions
  where draft_id = p_draft_id
  order by version_no desc
  limit 1;

  -- Never write a version identical to the latest snapshot.
  if v_latest.id is not null
     and v_latest.subject = v_draft.subject
     and v_latest.body_json = v_draft.body_json then
    return jsonb_build_object('version_no', v_latest.version_no, 'version_created', false);
  end if;

  v_next_no := coalesce(v_latest.version_no, 0) + 1;
  insert into public.draft_versions
    (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
  values
    (v_draft.workspace_id, v_draft.id, v_next_no, v_draft.revision, v_draft.subject, v_draft.body_json, p_reason, v_uid);

  return jsonb_build_object('version_no', v_next_no, 'version_created', true);
end;
$$;
comment on function public.checkpoint_draft(uuid, bigint, text) is
  'Phase 2 RPC: snapshot current draft content without touching the draft; dedupes identical snapshots.';

-- 4.4 restore_draft_version -------------------------------------------------------
create or replace function public.restore_draft_version(
  p_draft_id uuid,
  p_version_id uuid,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
  v_version public.draft_versions;
  v_latest public.draft_versions;
  v_next_no bigint;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_draft
  from public.drafts
  where id = p_draft_id
  for update;
  if not found then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409';
  end if;

  -- The version must belong to this draft in this workspace.
  select * into v_version
  from public.draft_versions
  where id = p_version_id
    and draft_id = p_draft_id
    and workspace_id = v_draft.workspace_id;
  if not found then
    raise exception 'version not found for this draft' using errcode = 'P0002';
  end if;

  select * into v_latest
  from public.draft_versions
  where draft_id = p_draft_id
  order by version_no desc
  limit 1;
  v_next_no := coalesce(v_latest.version_no, 0) + 1;

  -- Preserve the pre-restore state if it is not already snapshotted.
  if v_latest.id is null
     or v_latest.subject is distinct from v_draft.subject
     or v_latest.body_json is distinct from v_draft.body_json then
    insert into public.draft_versions
      (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
    values
      (v_draft.workspace_id, v_draft.id, v_next_no, v_draft.revision, v_draft.subject, v_draft.body_json, 'manual_checkpoint', v_uid);
    v_next_no := v_next_no + 1;
  end if;

  update public.drafts
  set subject = v_version.subject,
      body_json = v_version.body_json,
      revision = revision + 1,
      updated_by = v_uid,
      updated_at = now()
  where id = p_draft_id
  returning * into v_draft;

  insert into public.draft_versions
    (workspace_id, draft_id, version_no, source_revision, subject, body_json, reason, created_by)
  values
    (v_draft.workspace_id, v_draft.id, v_next_no, v_draft.revision, v_version.subject, v_version.body_json, 'restore', v_uid);

  return jsonb_build_object(
    'revision', v_draft.revision,
    'restored_from_version_no', v_version.version_no
  );
end;
$$;
comment on function public.restore_draft_version(uuid, uuid, bigint) is
  'Phase 2 RPC: restore a historical version (P0409 on stale revision); checkpoints unsaved state first and appends a ''restore'' version, so history is never lost.';

-- 4.5 create_template_version -----------------------------------------------------
create or replace function public.create_template_version(
  p_template_id uuid,
  p_subject_template text,
  p_body_template_json jsonb,
  p_variable_schema jsonb
) returns public.draft_template_versions
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_template public.draft_templates;
  v_row public.draft_template_versions;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Row lock serializes concurrent version creation per template.
  select * into v_template
  from public.draft_templates
  where id = p_template_id
  for update;
  if not found then
    raise exception 'template not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_template.workspace_id) then
    raise exception 'template not found or access denied' using errcode = 'P0002';
  end if;

  insert into public.draft_template_versions
    (workspace_id, template_id, version_no, subject_template, body_template_json, variable_schema, created_by)
  select v_template.workspace_id, v_template.id,
         coalesce(max(tv.version_no), 0) + 1,
         coalesce(p_subject_template, ''), p_body_template_json,
         coalesce(p_variable_schema, '[]'::jsonb), v_uid
  from public.draft_template_versions tv
  where tv.template_id = p_template_id
  returning * into v_row;

  update public.draft_templates
  set updated_at = now()
  where id = p_template_id;

  return v_row;
end;
$$;
comment on function public.create_template_version(uuid, text, jsonb, jsonb) is
  'Phase 2 RPC: append the next template version (max+1 under row lock) and bump the template''s updated_at.';

-- 4.6 set_default_signature --------------------------------------------------------
create or replace function public.set_default_signature(
  p_signature_id uuid
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_sig public.signatures;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Signatures RLS is owner-only, so non-owners simply see nothing here.
  select * into v_sig
  from public.signatures
  where id = p_signature_id
  for update;
  if not found then
    raise exception 'signature not found or access denied' using errcode = 'P0002';
  end if;
  if v_sig.owner_user_id <> v_uid then
    raise exception 'signature not found or access denied' using errcode = 'P0002';
  end if;

  -- Clear-then-set keeps the partial unique index satisfied mid-transaction.
  update public.signatures
  set is_default = false,
      updated_at = now()
  where workspace_id = v_sig.workspace_id
    and owner_user_id = v_sig.owner_user_id
    and is_default
    and id <> p_signature_id;

  update public.signatures
  set is_default = true,
      updated_at = now()
  where id = p_signature_id
    and not is_default;
end;
$$;
comment on function public.set_default_signature(uuid) is
  'Phase 2 RPC: atomically make a signature the owner''s single default in its workspace.';

-- 4.7 create_attachment_intent -------------------------------------------------------
create or replace function public.create_attachment_intent(
  p_draft_id uuid,
  p_original_filename text,
  p_mime_type text,
  p_size_bytes bigint
) returns public.draft_attachments
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
  v_count bigint;
  v_total bigint;
  v_safe text;
  v_ext text;
  v_id uuid;
  v_path text;
  v_row public.draft_attachments;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_original_filename is null or char_length(p_original_filename) < 1
     or char_length(p_original_filename) > 255 then
    raise exception 'original filename must be 1..255 characters' using errcode = '22023';
  end if;
  if p_mime_type is null or p_mime_type not in (
    'application/pdf', 'image/png', 'image/jpeg', 'text/plain'
  ) then
    raise exception 'attachment type forbidden: %', coalesce(p_mime_type, '<null>')
      using errcode = '22023';
  end if;
  if p_size_bytes is null or p_size_bytes <= 0 or p_size_bytes > 10485760 then
    raise exception 'attachment size must be 1..10485760 bytes' using errcode = '22023';
  end if;

  -- Lock the draft row to serialize concurrent intents against the limits.
  select * into v_draft
  from public.drafts
  where id = p_draft_id
  for update;
  if not found then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;

  select count(*), coalesce(sum(a.size_bytes), 0)
  into v_count, v_total
  from public.draft_attachments a
  where a.draft_id = p_draft_id
    and a.status <> 'deleted';

  if v_count >= 10 then
    raise exception 'attachment limit exceeded: max 10 attachments per draft'
      using errcode = '54000';
  end if;
  if v_total + p_size_bytes > 26214400 then
    raise exception 'attachment limit exceeded: max 26214400 total bytes per draft'
      using errcode = '54000';
  end if;

  -- Derive the safe filename: lowercase, keep [a-z0-9._-], collapse the rest
  -- into single dashes, trim leading/trailing punctuation, fall back to
  -- 'attachment', and truncate to 200 chars preserving a sane extension.
  v_safe := lower(p_original_filename);
  v_safe := regexp_replace(v_safe, '[^a-z0-9._-]+', '-', 'g');
  v_safe := regexp_replace(v_safe, '-{2,}', '-', 'g');
  v_safe := regexp_replace(v_safe, '^[-.]+', '');
  v_safe := regexp_replace(v_safe, '[-.]+$', '');
  if v_safe = '' then
    v_safe := 'attachment';
  end if;
  if char_length(v_safe) > 200 then
    v_ext := substring(v_safe from '\.([a-z0-9]{1,10})$');
    if v_ext is not null then
      v_safe := left(v_safe, 200 - char_length(v_ext) - 1) || '.' || v_ext;
    else
      v_safe := left(v_safe, 200);
    end if;
  end if;
  if v_safe !~ '^[A-Za-z0-9._-]{1,200}$' then
    raise exception 'could not derive a safe filename from %', p_original_filename
      using errcode = '22023';
  end if;

  v_id := gen_random_uuid();
  v_path := v_draft.workspace_id::text || '/' || p_draft_id::text || '/' || v_id::text || '/' || v_safe;

  insert into public.draft_attachments
    (id, workspace_id, draft_id, storage_bucket, storage_path,
     original_filename, safe_filename, mime_type, size_bytes, status, created_by)
  values
    (v_id, v_draft.workspace_id, p_draft_id, 'draft-attachments', v_path,
     p_original_filename, v_safe, p_mime_type, p_size_bytes, 'pending', v_uid)
  returning * into v_row;

  return v_row;
end;
$$;
comment on function public.create_attachment_intent(uuid, text, text, bigint) is
  'Phase 2 RPC: validate MIME/size/count/total limits, derive the safe filename and deterministic storage path, and insert a pending attachment row.';

-- 4.8 finalize_attachment --------------------------------------------------------------
create or replace function public.finalize_attachment(
  p_attachment_id uuid,
  p_sha256 text default null
) returns public.draft_attachments
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_att public.draft_attachments;
  v_obj_size bigint;
  v_obj_found boolean := false;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_att
  from public.draft_attachments
  where id = p_attachment_id
  for update;
  if not found then
    raise exception 'attachment not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_att.workspace_id) then
    raise exception 'attachment not found or access denied' using errcode = 'P0002';
  end if;
  if v_att.status not in ('pending', 'failed') then
    raise exception 'attachment cannot be finalized from status %', v_att.status
      using errcode = '55000';
  end if;

  select true, (o.metadata ->> 'size')::bigint
  into v_obj_found, v_obj_size
  from storage.objects o
  where o.bucket_id = 'draft-attachments'
    and o.name = v_att.storage_path;

  if not coalesce(v_obj_found, false)
     or (v_obj_size is not null and v_obj_size <> v_att.size_bytes) then
    -- Mark failed, then raise. NOTE: when PostgREST rolls the transaction
    -- back on error, the failed status is rolled back with it; callers using
    -- explicit transactions can persist it by catching the exception.
    update public.draft_attachments
    set status = 'failed'
    where id = p_attachment_id;
    if not coalesce(v_obj_found, false) then
      raise exception 'upload verification failed: storage object % is missing', v_att.storage_path
        using errcode = '55000';
    end if;
    raise exception 'upload verification failed: object size % does not match declared %', v_obj_size, v_att.size_bytes
      using errcode = '55000';
  end if;

  update public.draft_attachments
  set status = 'ready',
      verified_at = now(),
      sha256 = coalesce(p_sha256, sha256)
  where id = p_attachment_id
  returning * into v_att;

  return v_att;
end;
$$;
comment on function public.finalize_attachment(uuid, text) is
  'Phase 2 RPC: verify the uploaded storage object (existence + size) and promote the attachment to ready; raises 55000 when verification fails.';

-- 4.9 mark_attachment_deleted ------------------------------------------------------------
create or replace function public.mark_attachment_deleted(
  p_attachment_id uuid
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_att public.draft_attachments;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select * into v_att
  from public.draft_attachments
  where id = p_attachment_id
  for update;
  if not found then
    raise exception 'attachment not found or access denied' using errcode = 'P0002';
  end if;
  if not public.is_workspace_member(v_att.workspace_id) then
    raise exception 'attachment not found or access denied' using errcode = 'P0002';
  end if;
  if v_att.status = 'deleted' then
    return; -- idempotent
  end if;

  -- The storage object must already be gone; metadata only trails reality.
  if exists (
    select 1 from storage.objects o
    where o.bucket_id = 'draft-attachments'
      and o.name = v_att.storage_path
  ) then
    raise exception 'storage object % still exists; remove it before marking deleted', v_att.storage_path
      using errcode = '55000';
  end if;

  update public.draft_attachments
  set status = 'deleted',
      deleted_at = now()
  where id = p_attachment_id;
end;
$$;
comment on function public.mark_attachment_deleted(uuid) is
  'Phase 2 RPC: tombstone an attachment row after (and only after) its storage object has been removed.';

-- RPC execution grants: authenticated (and service_role) only.
revoke execute on function public.create_draft(uuid, text, jsonb) from public, anon;
revoke execute on function public.save_draft(uuid, bigint, text, jsonb, text) from public, anon;
revoke execute on function public.checkpoint_draft(uuid, bigint, text) from public, anon;
revoke execute on function public.restore_draft_version(uuid, uuid, bigint) from public, anon;
revoke execute on function public.create_template_version(uuid, text, jsonb, jsonb) from public, anon;
revoke execute on function public.set_default_signature(uuid) from public, anon;
revoke execute on function public.create_attachment_intent(uuid, text, text, bigint) from public, anon;
revoke execute on function public.finalize_attachment(uuid, text) from public, anon;
revoke execute on function public.mark_attachment_deleted(uuid) from public, anon;

grant execute on function public.create_draft(uuid, text, jsonb) to authenticated, service_role;
grant execute on function public.save_draft(uuid, bigint, text, jsonb, text) to authenticated, service_role;
grant execute on function public.checkpoint_draft(uuid, bigint, text) to authenticated, service_role;
grant execute on function public.restore_draft_version(uuid, uuid, bigint) to authenticated, service_role;
grant execute on function public.create_template_version(uuid, text, jsonb, jsonb) to authenticated, service_role;
grant execute on function public.set_default_signature(uuid) to authenticated, service_role;
grant execute on function public.create_attachment_intent(uuid, text, text, bigint) to authenticated, service_role;
grant execute on function public.finalize_attachment(uuid, text) to authenticated, service_role;
grant execute on function public.mark_attachment_deleted(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Table grants
-- ---------------------------------------------------------------------------
-- anon gets nothing at all on Phase 2 tables; version tables are append-only
-- for authenticated (select+insert only) — cascade deletes still work because
-- referential actions run with table-owner rights.

revoke all on table
  public.drafts, public.draft_versions,
  public.draft_templates, public.draft_template_versions,
  public.signatures, public.draft_attachments
from public, anon;

grant select, insert, update, delete on table
  public.drafts, public.draft_templates,
  public.signatures, public.draft_attachments
to authenticated;

grant select, insert on table
  public.draft_versions, public.draft_template_versions
to authenticated;

grant all on table
  public.drafts, public.draft_versions,
  public.draft_templates, public.draft_template_versions,
  public.signatures, public.draft_attachments
to service_role;

-- ---------------------------------------------------------------------------
-- 6. Row Level Security
-- ---------------------------------------------------------------------------

alter table public.drafts enable row level security;
alter table public.draft_versions enable row level security;
alter table public.draft_templates enable row level security;
alter table public.draft_template_versions enable row level security;
alter table public.signatures enable row level security;
alter table public.draft_attachments enable row level security;

-- 6.1 drafts: shared inside the workspace.
drop policy if exists drafts_select_members on public.drafts;
create policy drafts_select_members on public.drafts
  for select to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy drafts_select_members on public.drafts is
  'Phase 2: workspace members read all drafts of their workspaces.';

drop policy if exists drafts_insert_members on public.drafts;
create policy drafts_insert_members on public.drafts
  for insert to authenticated
  with check (
    public.is_workspace_member(workspace_id)
    and created_by = auth.uid()
    and updated_by = auth.uid()
  );
comment on policy drafts_insert_members on public.drafts is
  'Phase 2: members create drafts in their own name only.';

drop policy if exists drafts_update_members on public.drafts;
create policy drafts_update_members on public.drafts
  for update to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (
    public.is_workspace_member(workspace_id)
    and updated_by = auth.uid()
  );
comment on policy drafts_update_members on public.drafts is
  'Phase 2: members update workspace drafts; updated_by must be the caller.';

drop policy if exists drafts_delete_members on public.drafts;
create policy drafts_delete_members on public.drafts
  for delete to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy drafts_delete_members on public.drafts is
  'Phase 2: members delete workspace drafts.';

-- 6.2 draft_versions: append-only history (no UPDATE/DELETE policies at all).
drop policy if exists draft_versions_select_members on public.draft_versions;
create policy draft_versions_select_members on public.draft_versions
  for select to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy draft_versions_select_members on public.draft_versions is
  'Phase 2: workspace members read version history.';

drop policy if exists draft_versions_insert_members on public.draft_versions;
create policy draft_versions_insert_members on public.draft_versions
  for insert to authenticated
  with check (
    public.is_workspace_member(workspace_id)
    and created_by = auth.uid()
  );
comment on policy draft_versions_insert_members on public.draft_versions is
  'Phase 2: members append snapshots in their own name only.';

-- 6.3 draft_templates: workspace-shared.
drop policy if exists draft_templates_select_members on public.draft_templates;
create policy draft_templates_select_members on public.draft_templates
  for select to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy draft_templates_select_members on public.draft_templates is
  'Phase 2: workspace members read templates.';

drop policy if exists draft_templates_insert_members on public.draft_templates;
create policy draft_templates_insert_members on public.draft_templates
  for insert to authenticated
  with check (
    public.is_workspace_member(workspace_id)
    and created_by = auth.uid()
  );
comment on policy draft_templates_insert_members on public.draft_templates is
  'Phase 2: members create templates in their own name only.';

drop policy if exists draft_templates_update_members on public.draft_templates;
create policy draft_templates_update_members on public.draft_templates
  for update to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));
comment on policy draft_templates_update_members on public.draft_templates is
  'Phase 2: members update workspace templates.';

drop policy if exists draft_templates_delete_members on public.draft_templates;
create policy draft_templates_delete_members on public.draft_templates
  for delete to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy draft_templates_delete_members on public.draft_templates is
  'Phase 2: members delete workspace templates.';

-- 6.4 draft_template_versions: append-only (no UPDATE/DELETE policies).
drop policy if exists draft_template_versions_select_members on public.draft_template_versions;
create policy draft_template_versions_select_members on public.draft_template_versions
  for select to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy draft_template_versions_select_members on public.draft_template_versions is
  'Phase 2: workspace members read template versions.';

drop policy if exists draft_template_versions_insert_members on public.draft_template_versions;
create policy draft_template_versions_insert_members on public.draft_template_versions
  for insert to authenticated
  with check (
    public.is_workspace_member(workspace_id)
    and created_by = auth.uid()
  );
comment on policy draft_template_versions_insert_members on public.draft_template_versions is
  'Phase 2: members append template versions in their own name only.';

-- 6.5 signatures: strictly private to their owner, even for SELECT.
drop policy if exists signatures_owner_all on public.signatures;
create policy signatures_owner_all on public.signatures
  for all to authenticated
  using (
    owner_user_id = auth.uid()
    and public.is_workspace_member(workspace_id)
  )
  with check (
    owner_user_id = auth.uid()
    and public.is_workspace_member(workspace_id)
  );
comment on policy signatures_owner_all on public.signatures is
  'Phase 2: signatures are visible and writable only by their owning workspace member.';

-- 6.6 draft_attachments: workspace-shared metadata.
drop policy if exists draft_attachments_select_members on public.draft_attachments;
create policy draft_attachments_select_members on public.draft_attachments
  for select to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy draft_attachments_select_members on public.draft_attachments is
  'Phase 2: workspace members read attachment metadata.';

drop policy if exists draft_attachments_insert_members on public.draft_attachments;
create policy draft_attachments_insert_members on public.draft_attachments
  for insert to authenticated
  with check (
    public.is_workspace_member(workspace_id)
    and created_by = auth.uid()
  );
comment on policy draft_attachments_insert_members on public.draft_attachments is
  'Phase 2: members create attachment rows in their own name only.';

drop policy if exists draft_attachments_update_members on public.draft_attachments;
create policy draft_attachments_update_members on public.draft_attachments
  for update to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));
comment on policy draft_attachments_update_members on public.draft_attachments is
  'Phase 2: members update attachment metadata (integrity triggers gate ready).';

drop policy if exists draft_attachments_delete_members on public.draft_attachments;
create policy draft_attachments_delete_members on public.draft_attachments
  for delete to authenticated
  using (public.is_workspace_member(workspace_id));
comment on policy draft_attachments_delete_members on public.draft_attachments is
  'Phase 2: members delete attachment metadata rows.';

-- ---------------------------------------------------------------------------
-- 7. Storage: bucket + object policies
-- ---------------------------------------------------------------------------

-- Private bucket for draft attachments (idempotent).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'draft-attachments',
  'draft-attachments',
  false,
  10485760,
  array['application/pdf', 'image/png', 'image/jpeg', 'text/plain']
)
on conflict (id) do nothing;

-- Object access is keyed off the first path segment (the workspace uuid):
-- SELECT / INSERT / DELETE for workspace members, and deliberately NO UPDATE
-- policy (objects are immutable; replace = delete + re-upload + re-finalize).
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'draft_attachments_objects_select_members'
  ) then
    create policy draft_attachments_objects_select_members on storage.objects
      for select to authenticated
      using (
        bucket_id = 'draft-attachments'
        and public.is_workspace_member(((storage.foldername(name))[1])::uuid)
      );
    comment on policy draft_attachments_objects_select_members on storage.objects is
      'Phase 2: members read draft-attachment objects under their workspace prefix.';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'draft_attachments_objects_insert_members'
  ) then
    create policy draft_attachments_objects_insert_members on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'draft-attachments'
        and public.is_workspace_member(((storage.foldername(name))[1])::uuid)
      );
    comment on policy draft_attachments_objects_insert_members on storage.objects is
      'Phase 2: members upload draft-attachment objects only under their workspace prefix.';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'draft_attachments_objects_delete_members'
  ) then
    create policy draft_attachments_objects_delete_members on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'draft-attachments'
        and public.is_workspace_member(((storage.foldername(name))[1])::uuid)
      );
    comment on policy draft_attachments_objects_delete_members on storage.objects is
      'Phase 2: members remove draft-attachment objects under their workspace prefix.';
  end if;
end
$$;

-- ============================================================================
-- End of migration 20260711130000_draft_lifecycle.sql
-- ============================================================================
