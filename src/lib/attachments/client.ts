/**
 * Typed client for the Phase 2 attachment API routes, plus a thin wrapper
 * for the browser-side Supabase Storage upload.
 *
 * - Structured errors only: non-2xx responses are mapped to
 *   AttachmentClientError with the server's ApiError code; nothing else is
 *   surfaced and file contents are never logged.
 * - No transport code and no direct @supabase/supabase-js import: the
 *   storage client is accepted as a minimal structural parameter so tests
 *   can stub it.
 */

import {
  ATTACHMENT_BUCKET,
  type ApiError,
  type ApiErrorCode,
  type AttachmentRecord,
} from "@/lib/phase2/contracts";

export class AttachmentClientError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number;
  readonly details?: string[];

  constructor(
    code: ApiErrorCode,
    message: string,
    status: number,
    details?: string[],
  ) {
    super(message);
    this.name = "AttachmentClientError";
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

export interface AttachmentRequestOptions {
  signal?: AbortSignal;
  /** Injectable for tests; defaults to the global fetch. */
  fetchImpl?: typeof fetch;
}

export interface CreateAttachmentIntentBody {
  originalFilename: string;
  mimeType: string;
  sizeBytes: number;
}

export interface CreateAttachmentIntentResult {
  attachment: AttachmentRecord;
  uploadPath: string;
}

export interface FinalizeAttachmentBody {
  sha256?: string;
}

function attachmentsBasePath(workspaceId: string, draftId: string): string {
  return `/api/workspaces/${encodeURIComponent(workspaceId)}/drafts/${encodeURIComponent(draftId)}/attachments`;
}

function isApiError(value: unknown): value is ApiError {
  if (typeof value !== "object" || value === null) return false;
  const error = (value as { error?: unknown }).error;
  if (typeof error !== "object" || error === null) return false;
  const { code, message } = error as { code?: unknown; message?: unknown };
  return typeof code === "string" && typeof message === "string";
}

async function request<T>(
  path: string,
  init: RequestInit,
  options?: AttachmentRequestOptions,
): Promise<T> {
  const fetchImpl = options?.fetchImpl ?? fetch;
  const response = await fetchImpl(path, {
    ...init,
    signal: options?.signal,
    headers: {
      accept: "application/json",
      ...(init.body !== undefined
        ? { "content-type": "application/json" }
        : {}),
    },
  });
  if (!response.ok) {
    let payload: unknown = null;
    try {
      payload = await response.json();
    } catch {
      // Non-JSON error body: fall through to the generic structured error.
    }
    if (isApiError(payload)) {
      throw new AttachmentClientError(
        payload.error.code,
        payload.error.message,
        response.status,
        payload.error.details,
      );
    }
    throw new AttachmentClientError(
      "internal_error",
      `Attachment request failed with status ${response.status}.`,
      response.status,
    );
  }
  return (await response.json()) as T;
}

/**
 * POST /attachments — creates the server-side intent row (status "pending")
 * and returns the deterministic storage path the browser must upload to.
 */
export async function createAttachmentIntent(
  workspaceId: string,
  draftId: string,
  body: CreateAttachmentIntentBody,
  options?: AttachmentRequestOptions,
): Promise<CreateAttachmentIntentResult> {
  return request<CreateAttachmentIntentResult>(
    attachmentsBasePath(workspaceId, draftId),
    { method: "POST", body: JSON.stringify(body) },
    options,
  );
}

/**
 * POST /attachments/:aid/finalize — the server verifies the uploaded object
 * before the attachment becomes "ready" (422 attachment_not_verified
 * otherwise).
 */
export async function finalizeAttachment(
  workspaceId: string,
  draftId: string,
  attachmentId: string,
  body: FinalizeAttachmentBody = {},
  options?: AttachmentRequestOptions,
): Promise<{ attachment: AttachmentRecord }> {
  return request<{ attachment: AttachmentRecord }>(
    `${attachmentsBasePath(workspaceId, draftId)}/${encodeURIComponent(attachmentId)}/finalize`,
    { method: "POST", body: JSON.stringify(body) },
    options,
  );
}

/**
 * DELETE /attachments/:aid — the server removes the storage object first
 * and only then marks the row deleted.
 */
export async function deleteAttachment(
  workspaceId: string,
  draftId: string,
  attachmentId: string,
  options?: AttachmentRequestOptions,
): Promise<{ attachment: AttachmentRecord }> {
  return request<{ attachment: AttachmentRecord }>(
    `${attachmentsBasePath(workspaceId, draftId)}/${encodeURIComponent(attachmentId)}`,
    { method: "DELETE" },
    options,
  );
}

/** GET /attachments — lists the draft's attachment records. */
export async function listAttachments(
  workspaceId: string,
  draftId: string,
  options?: AttachmentRequestOptions,
): Promise<{ attachments: AttachmentRecord[] }> {
  return request<{ attachments: AttachmentRecord[] }>(
    attachmentsBasePath(workspaceId, draftId),
    { method: "GET" },
    options,
  );
}

// ---------------------------------------------------------------------------
// Storage upload (browser-side, authenticated Supabase client)
// ---------------------------------------------------------------------------

export interface StorageUploadOptions {
  upsert?: boolean;
  contentType?: string;
}

export interface StorageUploadResult {
  data: { path: string } | null;
  error: { message: string } | null;
}

/** Minimal structural slice of a Supabase client — stubbable in tests. */
export interface SupabaseStorageLike {
  storage: {
    from(bucket: string): {
      upload(
        path: string,
        file: Blob,
        options?: StorageUploadOptions,
      ): Promise<StorageUploadResult>;
    };
  };
}

export interface UploadableFile extends Blob {
  readonly type: string;
}

/**
 * Uploads the file bytes to the "draft-attachments" bucket at the exact
 * path returned by the intent route. Never overwrites (upsert: false).
 */
export async function uploadAttachmentObject(
  client: SupabaseStorageLike,
  uploadPath: string,
  file: UploadableFile,
): Promise<{ path: string }> {
  const { data, error } = await client.storage
    .from(ATTACHMENT_BUCKET)
    .upload(uploadPath, file, {
      upsert: false,
      contentType: file.type || "application/octet-stream",
    });
  if (error !== null || data === null) {
    throw new AttachmentClientError(
      "internal_error",
      error?.message ?? "Attachment upload failed.",
      0,
    );
  }
  return { path: data.path };
}
