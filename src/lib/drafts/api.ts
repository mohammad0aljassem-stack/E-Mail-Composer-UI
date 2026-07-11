/**
 * Thin typed client for the Phase 2 draft-lifecycle HTTP API.
 *
 * Every non-2xx response is mapped to a {@link DraftApiError} carrying the
 * structured error code from the server (plus `currentRevision` for
 * revision conflicts). This module never logs draft content — errors carry
 * structural information only.
 */

import type { DraftDocument } from "@/lib/composer/canonical";
import type {
  ApiError,
  ApiErrorCode,
  DraftRecord,
  DraftSaveReason,
  DraftVersionRecord,
  SaveDraftResult,
} from "@/lib/phase2/contracts";

export class DraftApiError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number;
  /** For `revision_conflict`: the revision currently stored on the server. */
  readonly currentRevision: number | undefined;

  constructor(options: {
    code: ApiErrorCode;
    status: number;
    message: string;
    currentRevision?: number;
  }) {
    super(options.message);
    this.name = "DraftApiError";
    this.code = options.code;
    this.status = options.status;
    this.currentRevision = options.currentRevision;
  }
}

export interface RequestOptions {
  signal?: AbortSignal;
}

export interface SaveDraftInput {
  expectedRevision: number;
  subject: string;
  document: DraftDocument;
  saveReason: DraftSaveReason;
}

export interface CreateDraftInput {
  subject: string;
  document: DraftDocument;
}

export interface RestoreVersionResult {
  revision: number;
  restored_from_version_no: number;
}

async function toDraftApiError(response: Response): Promise<DraftApiError> {
  let code: ApiErrorCode =
    response.status === 401 ? "unauthorized" : "internal_error";
  let message = `Request failed (HTTP ${response.status}).`;
  let currentRevision: number | undefined;
  try {
    const body = (await response.json()) as Partial<ApiError>;
    const error = body?.error;
    if (error && typeof error.code === "string") {
      code = error.code;
      if (typeof error.message === "string" && error.message.length > 0) {
        message = error.message;
      }
      if (typeof error.currentRevision === "number") {
        currentRevision = error.currentRevision;
      }
    }
  } catch {
    // Non-JSON error body: keep the generic status-based error.
  }
  return new DraftApiError({
    code,
    status: response.status,
    message,
    currentRevision,
  });
}

async function request<T>(
  url: string,
  init: {
    method: "GET" | "POST" | "PATCH" | "DELETE";
    body?: unknown;
    signal?: AbortSignal;
  },
): Promise<T> {
  const response = await fetch(url, {
    method: init.method,
    ...(init.body !== undefined
      ? {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(init.body),
        }
      : {}),
    ...(init.signal ? { signal: init.signal } : {}),
  });
  if (!response.ok) {
    throw await toDraftApiError(response);
  }
  return (await response.json()) as T;
}

function draftsUrl(workspaceId: string): string {
  return `/api/workspaces/${encodeURIComponent(workspaceId)}/drafts`;
}

function draftUrl(workspaceId: string, draftId: string): string {
  return `${draftsUrl(workspaceId)}/${encodeURIComponent(draftId)}`;
}

/** GET /api/workspaces/:wid/drafts */
export async function listDrafts(
  workspaceId: string,
  options: RequestOptions = {},
): Promise<DraftRecord[]> {
  const result = await request<{ drafts: DraftRecord[] }>(
    draftsUrl(workspaceId),
    { method: "GET", signal: options.signal },
  );
  return result.drafts;
}

/** POST /api/workspaces/:wid/drafts */
export async function createDraft(
  workspaceId: string,
  input: CreateDraftInput,
  options: RequestOptions = {},
): Promise<DraftRecord> {
  const result = await request<{ draft: DraftRecord }>(draftsUrl(workspaceId), {
    method: "POST",
    body: { subject: input.subject, document: input.document },
    signal: options.signal,
  });
  return result.draft;
}

/** GET /api/workspaces/:wid/drafts/:did */
export async function getDraft(
  workspaceId: string,
  draftId: string,
  options: RequestOptions = {},
): Promise<DraftRecord> {
  const result = await request<{ draft: DraftRecord }>(
    draftUrl(workspaceId, draftId),
    { method: "GET", signal: options.signal },
  );
  return result.draft;
}

/** PATCH /api/workspaces/:wid/drafts/:did — optimistic-concurrency save. */
export async function saveDraft(
  workspaceId: string,
  draftId: string,
  input: SaveDraftInput,
  options: RequestOptions = {},
): Promise<SaveDraftResult> {
  return request<SaveDraftResult>(draftUrl(workspaceId, draftId), {
    method: "PATCH",
    body: {
      expectedRevision: input.expectedRevision,
      subject: input.subject,
      document: input.document,
      saveReason: input.saveReason,
    },
    signal: options.signal,
  });
}

/** DELETE /api/workspaces/:wid/drafts/:did — archive semantics. */
export async function archiveDraft(
  workspaceId: string,
  draftId: string,
  options: RequestOptions = {},
): Promise<{ archived: true }> {
  return request<{ archived: true }>(draftUrl(workspaceId, draftId), {
    method: "DELETE",
    signal: options.signal,
  });
}

/** GET /api/workspaces/:wid/drafts/:did/versions — newest first. */
export async function listDraftVersions(
  workspaceId: string,
  draftId: string,
  options: RequestOptions = {},
): Promise<DraftVersionRecord[]> {
  const result = await request<{ versions: DraftVersionRecord[] }>(
    `${draftUrl(workspaceId, draftId)}/versions`,
    { method: "GET", signal: options.signal },
  );
  return result.versions;
}

/** POST /api/workspaces/:wid/drafts/:did/versions/:vid/restore */
export async function restoreDraftVersion(
  workspaceId: string,
  draftId: string,
  versionId: string,
  input: { expectedRevision: number },
  options: RequestOptions = {},
): Promise<RestoreVersionResult> {
  return request<RestoreVersionResult>(
    `${draftUrl(workspaceId, draftId)}/versions/${encodeURIComponent(versionId)}/restore`,
    {
      method: "POST",
      body: { expectedRevision: input.expectedRevision },
      signal: options.signal,
    },
  );
}
