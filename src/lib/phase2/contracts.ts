/**
 * Phase 2 shared contracts — OWNED BY THE LEAD AGENT.
 *
 * Single source of truth for the DTO shapes, database row shapes, RPC names,
 * API routes, limits, and error codes shared between the draft-lifecycle,
 * template/signature, attachment, and API workstreams. Implementation
 * modules import from here; they must not redefine these shapes.
 */

import type { DraftDocument } from "@/lib/composer/canonical";

// ---------------------------------------------------------------------------
// Draft lifecycle
// ---------------------------------------------------------------------------

export type DraftStatus = "draft" | "archived";

export const DRAFT_SAVE_REASONS = [
  "initial",
  "autosave",
  "autosave_checkpoint",
  "manual_checkpoint",
  "before_template",
  "after_template",
  "before_signature",
  "after_signature",
  "restore",
] as const;

export type DraftSaveReason = (typeof DRAFT_SAVE_REASONS)[number];

export interface DraftRecord {
  id: string;
  workspace_id: string;
  subject: string;
  body_json: DraftDocument;
  status: DraftStatus;
  revision: number;
  created_by: string;
  updated_by: string;
  last_autosaved_at: string | null;
  archived_at: string | null;
  last_template_version_id: string | null;
  last_signature_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface DraftVersionRecord {
  id: string;
  workspace_id: string;
  draft_id: string;
  version_no: number;
  source_revision: number;
  subject: string;
  body_json: DraftDocument;
  reason: DraftSaveReason;
  created_by: string;
  created_at: string;
}

export interface SaveDraftResult {
  revision: number;
  updated_at: string;
  last_autosaved_at: string;
  version_created: boolean;
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

export interface TemplateRecord {
  id: string;
  workspace_id: string;
  name: string;
  description: string | null;
  archived_at: string | null;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface TemplateVariableSpec {
  key: string;
  label: string;
  required: boolean;
}

export interface TemplateVersionRecord {
  id: string;
  workspace_id: string;
  template_id: string;
  version_no: number;
  subject_template: string;
  /** Template document: Phase 1 canonical nodes plus the `variable` inline node. */
  body_template_json: unknown;
  variable_schema: TemplateVariableSpec[];
  created_by: string;
  created_at: string;
}

/** Strict identifier format for variable keys. */
export const TEMPLATE_VARIABLE_KEY_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

export interface SignatureRecord {
  id: string;
  workspace_id: string;
  owner_user_id: string;
  name: string;
  body_json: DraftDocument;
  is_default: boolean;
  created_at: string;
  updated_at: string;
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

export type AttachmentStatus = "pending" | "ready" | "failed" | "deleted";

export interface AttachmentRecord {
  id: string;
  workspace_id: string;
  draft_id: string;
  storage_bucket: string;
  storage_path: string;
  original_filename: string;
  safe_filename: string;
  mime_type: string;
  size_bytes: number;
  sha256: string | null;
  status: AttachmentStatus;
  created_by: string;
  verified_at: string | null;
  deleted_at: string | null;
  created_at: string;
}

/** Manifest entry consumed by the future Phase 3 transport worker. */
export interface AttachmentManifestItem {
  attachmentId: string;
  bucket: string;
  path: string;
  filename: string;
  contentType: string;
  sizeBytes: number;
  sha256: string | null;
}

export const ATTACHMENT_BUCKET = "draft-attachments";
export const ATTACHMENT_MAX_FILE_BYTES = 10 * 1024 * 1024; // 10 MiB
export const ATTACHMENT_MAX_COUNT_PER_DRAFT = 10;
export const ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT = 25 * 1024 * 1024; // 25 MiB
export const ATTACHMENT_ALLOWED_MIME_TYPES = [
  "application/pdf",
  "image/png",
  "image/jpeg",
  "text/plain",
] as const;

// ---------------------------------------------------------------------------
// RPC names (PostgreSQL functions exposed through PostgREST)
// ---------------------------------------------------------------------------

export const RPC = {
  createDraft: "create_draft",
  saveDraft: "save_draft",
  checkpointDraft: "checkpoint_draft",
  restoreDraftVersion: "restore_draft_version",
  archiveDraft: "archive_draft",
  createTemplateVersion: "create_template_version",
  setDefaultSignature: "set_default_signature",
  createAttachmentIntent: "create_attachment_intent",
  finalizeAttachment: "finalize_attachment",
  markAttachmentDeleted: "mark_attachment_deleted",
} as const;

// ---------------------------------------------------------------------------
// API error codes (structured errors; never stack traces)
// ---------------------------------------------------------------------------

export type ApiErrorCode =
  | "unauthorized"
  | "not_found"
  | "invalid_body"
  | "invalid_json"
  | "unsupported_media_type"
  | "payload_too_large"
  | "invalid_document"
  | "revision_conflict"
  | "missing_variables"
  | "attachment_limit_exceeded"
  | "attachment_type_forbidden"
  | "attachment_not_verified"
  | "internal_error";

export interface ApiError {
  error: {
    code: ApiErrorCode;
    message: string;
    details?: string[];
    /** For revision_conflict: the revision currently stored on the server. */
    currentRevision?: number;
    /** For missing_variables: the variable keys that still need values. */
    missingVariables?: string[];
  };
}

/** PostgreSQL error code raised by save/restore RPCs on a revision mismatch. */
export const PG_REVISION_CONFLICT_ERRCODE = "P0409";

/** Debounce and checkpoint policy shared by client and server. */
export const AUTOSAVE_DEBOUNCE_MS = 1500;
export const AUTOSAVE_CHECKPOINT_INTERVAL_MINUTES = 10;

export const API_MAX_JSON_BODY_BYTES = 512 * 1024;
