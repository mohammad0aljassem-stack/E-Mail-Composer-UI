-- ============================================================================
-- Phase 2 hardening — enforce RPC-only invariants at the database layer
-- Migration: 20260712100000_enforce_phase2_rpc_invariants.sql
--
-- CORRECTIVE, ADDITIVE and IDEMPOTENT. The original 20260711130000 migration
-- granted authenticated direct INSERT/UPDATE/DELETE on drafts /
-- draft_templates / signatures / draft_attachments (+ INSERT on the version
-- tables) and shipped its mutation RPCs as SECURITY INVOKER, so any member
-- could bypass every RPC-only invariant through direct PostgREST table DML.
--
-- This migration converts an environment that ran the ORIGINAL (insecure)
-- 20260711130000 into the same secure state produced by the AMENDED
-- 20260711130000:
--   * mutation RPCs become SECURITY DEFINER (the only write path);
--   * direct table privileges collapse to SELECT-only (+ the draft_templates /
--     signatures exceptions);
--   * the storage INSERT policy is re-scoped to a matching pending intent row.
--
-- Convergence guarantee: baseline -> amended-20260711130000 and
-- baseline -> original-20260711130000 -> this migration produce identical
-- security-relevant schema. It is safe when the amended migration is already
-- installed (it never weakens an already-secure definition) and is fully
-- re-runnable (apply twice = apply once). It uses only CREATE OR REPLACE,
-- DROP ... IF EXISTS, revoke/grant and DROP/CREATE POLICY, so it raises
-- cleanly rather than silently skipping if a conflicting object shape exists.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Drop the superseded SECURITY INVOKER RPC overloads.
--    Their argument lists changed (a p_workspace_id was threaded through, plus
--    save_draft's trace-pointer params), so CREATE OR REPLACE would leave the
--    old insecure overloads callable. Dropping by exact signature removes them;
--    IF EXISTS keeps this a no-op when the amended migration already ran.
-- ---------------------------------------------------------------------------
drop function if exists public.save_draft(uuid, bigint, text, jsonb, text);
drop function if exists public.checkpoint_draft(uuid, bigint, text);
drop function if exists public.restore_draft_version(uuid, uuid, bigint);
drop function if exists public.create_template_version(uuid, text, jsonb, jsonb);
drop function if exists public.create_attachment_intent(uuid, text, text, bigint);
drop function if exists public.finalize_attachment(uuid, text);
drop function if exists public.mark_attachment_deleted(uuid);

-- ---------------------------------------------------------------------------
-- 1. (Re)create helpers + SECURITY DEFINER RPCs and their EXECUTE grants.
--    create_draft and set_default_signature keep their original signatures;
--    CREATE OR REPLACE flips create_draft INVOKER -> DEFINER in place.
--    This block is byte-for-byte identical to section 4 of the amended
--    20260711130000, which is what makes the two deploy paths converge.
-- ---------------------------------------------------------------------------

-- 4.0 Shared helper functions ------------------------------------------------

create or replace function public.phase2_safe_filename(p_input text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_safe text;
  v_ext text;
begin
  if p_input is null then
    raise exception 'filename is required' using errcode = '22023';
  end if;
  -- Lowercase, then collapse EVERY disallowed byte (path separators '/' '\',
  -- percent-encoded separators like %2f, control characters, spaces, quotes,
  -- Unicode, ...) into single dashes. This makes '..'/'/'/encoded traversal
  -- structurally impossible in the derived name.
  v_safe := lower(p_input);
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
    v_safe := regexp_replace(v_safe, '[-.]+$', '');
    if v_safe = '' then
      v_safe := 'attachment';
    end if;
  end if;
  if v_safe !~ '^[A-Za-z0-9._-]{1,200}$' then
    raise exception 'could not derive a safe filename' using errcode = '22023';
  end if;
  return v_safe;
end;
$$;
comment on function public.phase2_safe_filename(text) is
  'Phase 2: deterministic filename normalizer. Output always satisfies the draft_attachments.safe_filename CHECK (^[A-Za-z0-9._-]{1,200}$) or raises 22023; neutralizes separators, encoded separators, control chars, leading/trailing punctuation, and overlong names.';

create or replace function public.phase2_validate_variable_schema(p_schema jsonb)
returns void
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_elem jsonb;
  v_key text;
  v_obj_key text;
  v_seen text[] := array[]::text[];
begin
  -- Mirrors src/lib/templates/template-document.ts::declaredVariables exactly:
  -- array of { key, label, required } objects; strict key format; bounded,
  -- non-empty label; boolean required; no unknown keys; no duplicate keys.
  if p_schema is null or jsonb_typeof(p_schema) <> 'array' then
    raise exception 'variable_schema must be a JSON array' using errcode = '22023';
  end if;
  for v_elem in select value from jsonb_array_elements(p_schema) as t(value) loop
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'variable_schema entry must be an object' using errcode = '22023';
    end if;
    for v_obj_key in select key from jsonb_object_keys(v_elem) as k(key) loop
      if v_obj_key not in ('key', 'label', 'required') then
        raise exception 'variable_schema entry has unsupported key %', v_obj_key
          using errcode = '22023';
      end if;
    end loop;
    if jsonb_typeof(v_elem -> 'key') is distinct from 'string'
       or (v_elem ->> 'key') !~ '^[a-z][a-z0-9_]{0,63}$' then
      raise exception 'variable_schema key must match ^[a-z][a-z0-9_]{0,63}$'
        using errcode = '22023';
    end if;
    if jsonb_typeof(v_elem -> 'label') is distinct from 'string'
       or btrim(v_elem ->> 'label') = ''
       or char_length(v_elem ->> 'label') > 200 then
      raise exception 'variable_schema label must be a non-empty string of at most 200 characters'
        using errcode = '22023';
    end if;
    if jsonb_typeof(v_elem -> 'required') is distinct from 'boolean' then
      raise exception 'variable_schema required must be a boolean'
        using errcode = '22023';
    end if;
    v_key := v_elem ->> 'key';
    if v_key = any(v_seen) then
      raise exception 'variable_schema has duplicate key %', v_key
        using errcode = '22023';
    end if;
    v_seen := array_append(v_seen, v_key);
  end loop;
end;
$$;
comment on function public.phase2_validate_variable_schema(jsonb) is
  'Phase 2: validates a template variable_schema in SQL, mirroring the application declaredVariables() contract (array of {key,label,required}); raises 22023 on any app-invalid-but-array-valid schema.';

-- 4.1 create_draft -------------------------------------------------------------
create or replace function public.create_draft(
  p_workspace_id uuid,
  p_subject text,
  p_body_json jsonb
) returns public.drafts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_workspace_id is null or not public.is_workspace_member(p_workspace_id) then
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
  'Phase 2 RPC (SECURITY DEFINER): atomically create a draft (revision 1) plus its initial version snapshot. DEFINER because drafts/draft_versions are SELECT-only for authenticated; authorization is enforced in-body via auth.uid()+is_workspace_member and never trusts client identity.';

-- 4.2 save_draft ---------------------------------------------------------------
create or replace function public.save_draft(
  p_draft_id uuid,
  p_workspace_id uuid,
  p_expected_revision bigint,
  p_subject text,
  p_body_json jsonb,
  p_save_reason text,
  p_last_template_version_id uuid default null,
  p_last_signature_id uuid default null
) returns jsonb
language plpgsql
security definer
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

  -- Lock the target row first (DEFINER bypasses RLS, so authorization is
  -- explicit): the row must exist, its workspace must equal the client's
  -- claimed workspace, and the caller must be a member of it.
  select * into v_draft
  from public.drafts
  where id = p_draft_id
  for update;
  if not found then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;

  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409', hint = 'current_revision=' || v_draft.revision;
  end if;

  -- Identical content: no revision bump. Still persist trace pointers if asked
  -- (template/signature application records the exact version/signature used).
  if v_draft.subject = v_subject and v_draft.body_json = p_body_json then
    if p_last_template_version_id is not null or p_last_signature_id is not null then
      update public.drafts
      set last_template_version_id = coalesce(p_last_template_version_id, last_template_version_id),
          last_signature_id = coalesce(p_last_signature_id, last_signature_id),
          updated_by = v_uid
      where id = p_draft_id
      returning * into v_draft;
    end if;
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
      last_autosaved_at = now(),
      last_template_version_id = coalesce(p_last_template_version_id, last_template_version_id),
      last_signature_id = coalesce(p_last_signature_id, last_signature_id)
  where id = p_draft_id
  returning * into v_draft;

  if p_save_reason = 'autosave' then
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
comment on function public.save_draft(uuid, uuid, bigint, text, jsonb, text, uuid, uuid) is
  'Phase 2 RPC (SECURITY DEFINER): optimistic-concurrency save. Raises P0409 with hint ''current_revision=N'' on a stale revision so PostgREST surfaces the current revision. No-op on identical content; optional p_last_template_version_id/p_last_signature_id record traceability pointers in the same locked update. DEFINER because drafts is SELECT-only for authenticated.';

-- 4.3 checkpoint_draft -----------------------------------------------------------
create or replace function public.checkpoint_draft(
  p_draft_id uuid,
  p_workspace_id uuid,
  p_expected_revision bigint,
  p_reason text
) returns jsonb
language plpgsql
security definer
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
  if v_draft.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409', hint = 'current_revision=' || v_draft.revision;
  end if;

  select * into v_latest
  from public.draft_versions
  where draft_id = p_draft_id
  order by version_no desc
  limit 1;

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
comment on function public.checkpoint_draft(uuid, uuid, bigint, text) is
  'Phase 2 RPC (SECURITY DEFINER): append a version snapshot of current content without touching the draft; dedupes identical snapshots; P0409 (with current_revision hint) on stale revision. DEFINER because draft_versions is SELECT-only for authenticated.';

-- 4.4 restore_draft_version -------------------------------------------------------
create or replace function public.restore_draft_version(
  p_draft_id uuid,
  p_workspace_id uuid,
  p_version_id uuid,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security definer
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
  if v_draft.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409', hint = 'current_revision=' || v_draft.revision;
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
comment on function public.restore_draft_version(uuid, uuid, uuid, bigint) is
  'Phase 2 RPC (SECURITY DEFINER): restore a historical version (P0409 with current_revision hint on stale revision); checkpoints unsaved state first and appends a restore version, never rewriting old rows. DEFINER because drafts/draft_versions are not directly writable by authenticated.';

-- 4.5 archive_draft ---------------------------------------------------------------
create or replace function public.archive_draft(
  p_draft_id uuid,
  p_workspace_id uuid,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
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
  if v_draft.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_draft.workspace_id) then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.revision <> p_expected_revision then
    raise exception 'revision conflict: expected %, current %', p_expected_revision, v_draft.revision
      using errcode = 'P0409', hint = 'current_revision=' || v_draft.revision;
  end if;

  if v_draft.status = 'archived' then
    return jsonb_build_object(
      'revision', v_draft.revision,
      'status', v_draft.status,
      'archived_at', v_draft.archived_at
    );
  end if;

  update public.drafts
  set status = 'archived',
      archived_at = now(),
      revision = revision + 1,
      updated_by = v_uid,
      updated_at = now()
  where id = p_draft_id
  returning * into v_draft;

  return jsonb_build_object(
    'revision', v_draft.revision,
    'status', v_draft.status,
    'archived_at', v_draft.archived_at
  );
end;
$$;
comment on function public.archive_draft(uuid, uuid, bigint) is
  'Phase 2 RPC (SECURITY DEFINER): archive a draft (status=archived, stamp archived_at + updated_by=auth.uid(), bump revision) under optimistic concurrency. Replaces the former direct UPDATE archive path now that drafts is SELECT-only for authenticated. Idempotent when already archived.';

-- 4.6 create_template_version -----------------------------------------------------
create or replace function public.create_template_version(
  p_template_id uuid,
  p_workspace_id uuid,
  p_subject_template text,
  p_body_template_json jsonb,
  p_variable_schema jsonb
) returns public.draft_template_versions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_template public.draft_templates;
  v_row public.draft_template_versions;
  v_schema jsonb := coalesce(p_variable_schema, '[]'::jsonb);
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Validate the FULL variable schema in SQL before any write.
  perform public.phase2_validate_variable_schema(v_schema);

  -- Row lock serializes concurrent version creation per template.
  select * into v_template
  from public.draft_templates
  where id = p_template_id
  for update;
  if not found then
    raise exception 'template not found or access denied' using errcode = 'P0002';
  end if;
  if v_template.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_template.workspace_id) then
    raise exception 'template not found or access denied' using errcode = 'P0002';
  end if;

  insert into public.draft_template_versions
    (workspace_id, template_id, version_no, subject_template, body_template_json, variable_schema, created_by)
  select v_template.workspace_id, v_template.id,
         coalesce(max(tv.version_no), 0) + 1,
         coalesce(p_subject_template, ''), p_body_template_json,
         v_schema, v_uid
  from public.draft_template_versions tv
  where tv.template_id = p_template_id
  returning * into v_row;

  update public.draft_templates
  set updated_at = now()
  where id = p_template_id;

  return v_row;
end;
$$;
comment on function public.create_template_version(uuid, uuid, text, jsonb, jsonb) is
  'Phase 2 RPC (SECURITY DEFINER): append the next immutable template version (max+1 under row lock) after validating the full variable schema (22023 on app-invalid schema). DEFINER because draft_template_versions is SELECT-only for authenticated.';

-- 4.7 set_default_signature --------------------------------------------------------
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
  'Phase 2 RPC (SECURITY INVOKER): atomically make a signature the owner''s single default in its workspace. INVOKER is acceptable because signatures remain direct-DML for their owner (owner-only RLS + partial unique index); the function still verifies ownership.';

-- 4.8 create_attachment_intent -------------------------------------------------------
create or replace function public.create_attachment_intent(
  p_draft_id uuid,
  p_workspace_id uuid,
  p_original_filename text,
  p_mime_type text,
  p_size_bytes bigint,
  p_sha256 text default null
) returns public.draft_attachments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_draft public.drafts;
  v_count bigint;
  v_total bigint;
  v_safe text;
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
  if p_sha256 is not null and p_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'sha256 must be 64 lowercase hex characters' using errcode = '22023';
  end if;

  -- Lock the draft row to serialize concurrent intents against the limits.
  select * into v_draft
  from public.drafts
  where id = p_draft_id
  for update;
  if not found then
    raise exception 'draft not found or access denied' using errcode = 'P0002';
  end if;
  if v_draft.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_draft.workspace_id) then
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

  v_safe := public.phase2_safe_filename(p_original_filename);

  v_id := gen_random_uuid();
  v_path := v_draft.workspace_id::text || '/' || p_draft_id::text || '/' || v_id::text || '/' || v_safe;

  insert into public.draft_attachments
    (id, workspace_id, draft_id, storage_bucket, storage_path,
     original_filename, safe_filename, mime_type, size_bytes, sha256, status, created_by)
  values
    (v_id, v_draft.workspace_id, p_draft_id, 'draft-attachments', v_path,
     p_original_filename, v_safe, p_mime_type, p_size_bytes, p_sha256, 'pending', v_uid)
  returning * into v_row;

  return v_row;
end;
$$;
comment on function public.create_attachment_intent(uuid, uuid, text, text, bigint, text) is
  'Phase 2 RPC (SECURITY DEFINER): under a draft row lock, validate MIME/size/count/aggregate limits, derive the safe filename (public.phase2_safe_filename) and deterministic storage path, and insert a pending attachment with created_by=auth.uid(). DEFINER because draft_attachments is SELECT-only for authenticated; the pending row is what authorizes the subsequent storage upload.';

-- 4.9 finalize_attachment --------------------------------------------------------------
create or replace function public.finalize_attachment(
  p_attachment_id uuid,
  p_workspace_id uuid,
  p_sha256 text default null
) returns public.draft_attachments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_att public.draft_attachments;
  v_obj_size bigint;
  v_obj_found boolean := false;
  v_count bigint;
  v_total bigint;
begin
  if v_uid is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_sha256 is not null and p_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'sha256 must be 64 lowercase hex characters' using errcode = '22023';
  end if;

  select * into v_att
  from public.draft_attachments
  where id = p_attachment_id
  for update;
  if not found then
    raise exception 'attachment not found or access denied' using errcode = 'P0002';
  end if;
  if v_att.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_att.workspace_id) then
    raise exception 'attachment not found or access denied' using errcode = 'P0002';
  end if;
  if v_att.status <> 'pending' then
    raise exception 'attachment cannot be finalized from status %', v_att.status
      using errcode = '55000';
  end if;

  -- Verify the uploaded object exists at the exact bucket+path and that the
  -- real object size equals the declared size_bytes.
  select true, (o.metadata ->> 'size')::bigint
  into v_obj_found, v_obj_size
  from storage.objects o
  where o.bucket_id = 'draft-attachments'
    and o.name = v_att.storage_path;

  if not coalesce(v_obj_found, false) then
    update public.draft_attachments set status = 'failed' where id = p_attachment_id;
    raise exception 'upload verification failed: storage object % is missing', v_att.storage_path
      using errcode = '55000';
  end if;
  if v_obj_size is null or v_obj_size <> v_att.size_bytes then
    update public.draft_attachments set status = 'failed' where id = p_attachment_id;
    raise exception 'upload verification failed: object size % does not match declared %', v_obj_size, v_att.size_bytes
      using errcode = '55000';
  end if;

  -- Re-check the per-draft count and aggregate size across non-deleted rows.
  select count(*), coalesce(sum(a.size_bytes), 0)
  into v_count, v_total
  from public.draft_attachments a
  where a.draft_id = v_att.draft_id
    and a.status <> 'deleted';
  if v_count > 10 or v_total > 26214400 then
    raise exception 'attachment limit exceeded on finalize' using errcode = '54000';
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
comment on function public.finalize_attachment(uuid, uuid, text) is
  'Phase 2 RPC (SECURITY DEFINER): promote a pending attachment to ready only after verifying the storage object exists at bucket+path and its real size equals size_bytes (55000 on mismatch), re-checking count/aggregate, and stamping verified_at server-side. Immutable fields are never rewritten. DEFINER because draft_attachments is SELECT-only for authenticated.';

-- 4.10 mark_attachment_deleted ------------------------------------------------------------
create or replace function public.mark_attachment_deleted(
  p_attachment_id uuid,
  p_workspace_id uuid
) returns void
language plpgsql
security definer
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
  if v_att.workspace_id <> p_workspace_id
     or not public.is_workspace_member(v_att.workspace_id) then
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
comment on function public.mark_attachment_deleted(uuid, uuid) is
  'Phase 2 RPC (SECURITY DEFINER): tombstone an attachment row after (and only after) its storage object has been removed. DEFINER because draft_attachments is SELECT-only for authenticated.';

-- RPC execution grants: authenticated (and service_role) only; never anon/public.
revoke execute on function public.phase2_safe_filename(text) from public, anon, authenticated;
revoke execute on function public.phase2_validate_variable_schema(jsonb) from public, anon, authenticated;
revoke execute on function public.create_draft(uuid, text, jsonb) from public, anon;
revoke execute on function public.save_draft(uuid, uuid, bigint, text, jsonb, text, uuid, uuid) from public, anon;
revoke execute on function public.checkpoint_draft(uuid, uuid, bigint, text) from public, anon;
revoke execute on function public.restore_draft_version(uuid, uuid, uuid, bigint) from public, anon;
revoke execute on function public.archive_draft(uuid, uuid, bigint) from public, anon;
revoke execute on function public.create_template_version(uuid, uuid, text, jsonb, jsonb) from public, anon;
revoke execute on function public.set_default_signature(uuid) from public, anon;
revoke execute on function public.create_attachment_intent(uuid, uuid, text, text, bigint, text) from public, anon;
revoke execute on function public.finalize_attachment(uuid, uuid, text) from public, anon;
revoke execute on function public.mark_attachment_deleted(uuid, uuid) from public, anon;

grant execute on function public.create_draft(uuid, text, jsonb) to authenticated, service_role;
grant execute on function public.save_draft(uuid, uuid, bigint, text, jsonb, text, uuid, uuid) to authenticated, service_role;
grant execute on function public.checkpoint_draft(uuid, uuid, bigint, text) to authenticated, service_role;
grant execute on function public.restore_draft_version(uuid, uuid, uuid, bigint) to authenticated, service_role;
grant execute on function public.archive_draft(uuid, uuid, bigint) to authenticated, service_role;
grant execute on function public.create_template_version(uuid, uuid, text, jsonb, jsonb) to authenticated, service_role;
grant execute on function public.set_default_signature(uuid) to authenticated, service_role;
grant execute on function public.create_attachment_intent(uuid, uuid, text, text, bigint, text) to authenticated, service_role;
grant execute on function public.finalize_attachment(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.mark_attachment_deleted(uuid, uuid) to authenticated, service_role;
-- Internal helper functions: callable only by their owner-rights callers / service_role.
grant execute on function public.phase2_safe_filename(text) to service_role;
grant execute on function public.phase2_validate_variable_schema(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Collapse direct table privileges to the secure model.
--    revoke-from-authenticated (not just anon/public) defeats the original
--    insecure grants and any inherited/default-ACL privilege.
-- ---------------------------------------------------------------------------
revoke all on table
  public.drafts, public.draft_versions,
  public.draft_templates, public.draft_template_versions,
  public.signatures, public.draft_attachments
from public, anon, authenticated;

grant select on table
  public.drafts, public.draft_versions,
  public.draft_templates, public.draft_template_versions,
  public.signatures, public.draft_attachments
to authenticated;

grant insert, update on table public.draft_templates to authenticated;
grant insert, update, delete on table public.signatures to authenticated;

grant all on table
  public.drafts, public.draft_versions,
  public.draft_templates, public.draft_template_versions,
  public.signatures, public.draft_attachments
to service_role;

-- ---------------------------------------------------------------------------
-- 3. Storage: ensure the private bucket exists and rebuild the object policies
--    in their hardened form (idempotent drop/create; no UPDATE policy).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'draft-attachments',
  'draft-attachments',
  false,
  10485760,
  array['application/pdf', 'image/png', 'image/jpeg', 'text/plain']
)
on conflict (id) do nothing;

drop policy if exists draft_attachments_objects_select_members on storage.objects;
create policy draft_attachments_objects_select_members on storage.objects
  for select to authenticated
  using (
    bucket_id = 'draft-attachments'
    and public.is_workspace_member(((storage.foldername(name))[1])::uuid)
  );
comment on policy draft_attachments_objects_select_members on storage.objects is
  'Phase 2: members read draft-attachment objects under their workspace prefix.';

drop policy if exists draft_attachments_objects_insert_members on storage.objects;
create policy draft_attachments_objects_insert_members on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'draft-attachments'
    and exists (
      select 1 from public.draft_attachments a
      where a.storage_path = name
        and a.status = 'pending'
        and a.created_by = auth.uid()
        and public.is_workspace_member(a.workspace_id)
    )
  );
comment on policy draft_attachments_objects_insert_members on storage.objects is
  'Phase 2 (hardened): an object may be uploaded only while a matching pending draft_attachments intent row exists (same storage_path, created by the caller, in a workspace the caller belongs to). Blocks arbitrary-path, wrong-workspace, wrong-draft and post-ready re-uploads.';

drop policy if exists draft_attachments_objects_delete_members on storage.objects;
create policy draft_attachments_objects_delete_members on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'draft-attachments'
    and public.is_workspace_member(((storage.foldername(name))[1])::uuid)
  );
comment on policy draft_attachments_objects_delete_members on storage.objects is
  'Phase 2: members remove draft-attachment objects under their workspace prefix.';

-- ============================================================================
-- End of migration 20260712100000_enforce_phase2_rpc_invariants.sql
-- ============================================================================
