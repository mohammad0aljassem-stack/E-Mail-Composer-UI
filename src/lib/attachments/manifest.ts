/**
 * Attachment manifest builder for the render package.
 *
 * The manifest is the only attachment data the future Phase 3 transport
 * worker consumes. It trusts nothing but rows that the server has verified:
 * status "ready" AND verified_at set AND not deleted. Everything else —
 * pending, failed, deleted, or ready-without-verification — is excluded.
 */

import type {
  AttachmentManifestItem,
  AttachmentRecord,
} from "@/lib/phase2/contracts";

function isVerifiedReady(record: AttachmentRecord): boolean {
  return (
    record.status === "ready" &&
    record.verified_at !== null &&
    record.deleted_at === null
  );
}

/** Deterministic order: created_at ascending, then id ascending. */
function compareRecords(a: AttachmentRecord, b: AttachmentRecord): number {
  if (a.created_at < b.created_at) return -1;
  if (a.created_at > b.created_at) return 1;
  if (a.id < b.id) return -1;
  if (a.id > b.id) return 1;
  return 0;
}

export function buildAttachmentManifest(
  attachments: AttachmentRecord[],
): AttachmentManifestItem[] {
  return attachments
    .filter(isVerifiedReady)
    .sort(compareRecords)
    .map((record) => ({
      attachmentId: record.id,
      bucket: record.storage_bucket,
      path: record.storage_path,
      filename: record.safe_filename,
      contentType: record.mime_type,
      sizeBytes: record.size_bytes,
      sha256: record.sha256,
    }));
}
