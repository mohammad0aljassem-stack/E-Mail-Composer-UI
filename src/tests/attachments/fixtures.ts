/** Shared attachment test fixtures. */

import {
  ATTACHMENT_BUCKET,
  type AttachmentRecord,
} from "@/lib/phase2/contracts";

let counter = 0;

export function makeAttachment(
  overrides: Partial<AttachmentRecord> = {},
): AttachmentRecord {
  counter += 1;
  const id = overrides.id ?? `att-${String(counter).padStart(4, "0")}`;
  const safeFilename = overrides.safe_filename ?? `file-${counter}.pdf`;
  return {
    id,
    workspace_id: "ws-1",
    draft_id: "draft-1",
    storage_bucket: ATTACHMENT_BUCKET,
    storage_path: `ws-1/draft-1/${id}/${safeFilename}`,
    original_filename: overrides.original_filename ?? safeFilename,
    safe_filename: safeFilename,
    mime_type: "application/pdf",
    size_bytes: 1024,
    sha256: null,
    status: "ready",
    created_by: "user-1",
    verified_at: "2026-07-01T10:00:00.000Z",
    deleted_at: null,
    created_at: "2026-07-01T09:00:00.000Z",
    ...overrides,
  };
}

/** A verified, ready attachment (included in manifests). */
export function readyAttachment(
  overrides: Partial<AttachmentRecord> = {},
): AttachmentRecord {
  return makeAttachment({
    status: "ready",
    verified_at: "2026-07-01T10:00:00.000Z",
    deleted_at: null,
    ...overrides,
  });
}

export function pendingAttachment(
  overrides: Partial<AttachmentRecord> = {},
): AttachmentRecord {
  return makeAttachment({
    status: "pending",
    verified_at: null,
    deleted_at: null,
    ...overrides,
  });
}

export function failedAttachment(
  overrides: Partial<AttachmentRecord> = {},
): AttachmentRecord {
  return makeAttachment({
    status: "failed",
    verified_at: null,
    deleted_at: null,
    ...overrides,
  });
}

export function deletedAttachment(
  overrides: Partial<AttachmentRecord> = {},
): AttachmentRecord {
  return makeAttachment({
    status: "deleted",
    verified_at: "2026-07-01T10:00:00.000Z",
    deleted_at: "2026-07-02T10:00:00.000Z",
    ...overrides,
  });
}
