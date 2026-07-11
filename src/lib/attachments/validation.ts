/**
 * Client-side attachment validation — pure module, no browser globals.
 *
 * Mirrors the server-side rules from the Phase 2 contracts so the UI can
 * reject bad selections before any upload starts. The server remains the
 * authority; this module never weakens its checks.
 */

import {
  ATTACHMENT_ALLOWED_MIME_TYPES,
  ATTACHMENT_MAX_COUNT_PER_DRAFT,
  ATTACHMENT_MAX_FILE_BYTES,
  ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT,
  type ApiErrorCode,
  type AttachmentRecord,
} from "@/lib/phase2/contracts";

const ALLOWED_MIME_TYPES: ReadonlySet<string> = new Set<string>(
  ATTACHMENT_ALLOWED_MIME_TYPES,
);

/**
 * Exact-match allowlist check (compared lowercase). Everything not in
 * ATTACHMENT_ALLOWED_MIME_TYPES — text/html, image/svg+xml, anything
 * JavaScript-ish, archives, executables — is forbidden by construction.
 */
export function isAllowedMimeType(mime: string): boolean {
  return typeof mime === "string" && ALLOWED_MIME_TYPES.has(mime.toLowerCase());
}

export const SANITIZED_FILENAME_MAX_LENGTH = 200;
export const SANITIZED_FILENAME_FALLBACK = "attachment";

/** Deterministic ASCII transliteration for common German characters. */
const TRANSLITERATIONS: ReadonlyArray<readonly [RegExp, string]> = [
  [/ä/g, "ae"],
  [/ö/g, "oe"],
  [/ü/g, "ue"],
  [/ß/g, "ss"],
];

/**
 * Reduces one filename segment to the safe alphabet [a-z0-9._-]:
 * lowercase, NFKD-decompose and strip combining marks, transliterate German
 * characters, replace runs of anything else with "-", collapse repeated
 * separators, and trim leading/trailing separators and dots.
 */
function sanitizePart(part: string): string {
  let s = part.toLowerCase().normalize("NFC");
  for (const [pattern, replacement] of TRANSLITERATIONS) {
    s = s.replace(pattern, replacement);
  }
  s = s.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
  s = s.replace(/[^a-z0-9._-]+/g, "-");
  // Collapse repeated separators deterministically until a fixed point.
  let previous: string;
  do {
    previous = s;
    s = s
      .replace(/\.{2,}/g, ".")
      .replace(/-{2,}/g, "-")
      .replace(/_{2,}/g, "_")
      .replace(/\.-|-\./g, ".")
      .replace(/_\.|\._/g, ".")
      .replace(/_-|-_/g, "-");
  } while (s !== previous);
  return s.replace(/^[._-]+/, "").replace(/[._-]+$/, "");
}

/**
 * Deterministic, never-empty safe filename: keeps only [a-z0-9._-],
 * preserves a sane extension when present, caps the total length at
 * SANITIZED_FILENAME_MAX_LENGTH, and falls back to "attachment".
 */
export function sanitizeFilename(original: string): string {
  const input = typeof original === "string" ? original.trim() : "";

  let base = input;
  let extension = "";
  const dotIndex = input.lastIndexOf(".");
  if (dotIndex > 0 && dotIndex < input.length - 1) {
    const candidate = sanitizePart(input.slice(dotIndex + 1));
    if (/^[a-z0-9]{1,10}$/.test(candidate)) {
      extension = candidate;
      base = input.slice(0, dotIndex);
    }
  }

  let safeBase = sanitizePart(base);
  if (safeBase.length === 0) {
    safeBase = SANITIZED_FILENAME_FALLBACK;
  }

  const maxBaseLength =
    extension.length > 0
      ? SANITIZED_FILENAME_MAX_LENGTH - extension.length - 1
      : SANITIZED_FILENAME_MAX_LENGTH;
  if (safeBase.length > maxBaseLength) {
    safeBase = safeBase.slice(0, maxBaseLength).replace(/[._-]+$/, "");
    if (safeBase.length === 0) {
      safeBase = SANITIZED_FILENAME_FALLBACK;
    }
  }

  return extension.length > 0 ? `${safeBase}.${extension}` : safeBase;
}

export interface AttachmentCandidate {
  originalFilename: string;
  mimeType: string;
  sizeBytes: number;
}

export type AttachmentPlanErrorCode = Extract<
  ApiErrorCode,
  "attachment_type_forbidden" | "attachment_limit_exceeded" | "invalid_body"
>;

export type AttachmentPlanResult =
  | { ok: true; safeFilename: string }
  | { ok: false; code: AttachmentPlanErrorCode; message: string };

function isActive(record: AttachmentRecord): boolean {
  return record.status !== "deleted" && record.deleted_at === null;
}

/**
 * Validates a candidate file against the allowlist, the per-file size limit,
 * the per-draft count limit, and the per-draft total-size limit (counting
 * only non-deleted attachments). Returns the deterministic safe filename on
 * success. Error messages never contain user-provided text.
 */
export function validateAttachmentPlan(
  existing: AttachmentRecord[],
  candidate: AttachmentCandidate,
): AttachmentPlanResult {
  if (!isAllowedMimeType(candidate.mimeType)) {
    return {
      ok: false,
      code: "attachment_type_forbidden",
      message: `File type is not allowed. Allowed types: ${ATTACHMENT_ALLOWED_MIME_TYPES.join(", ")}.`,
    };
  }
  if (!Number.isInteger(candidate.sizeBytes) || candidate.sizeBytes <= 0) {
    return {
      ok: false,
      code: "invalid_body",
      message: "File size must be a positive number of bytes.",
    };
  }
  if (candidate.sizeBytes > ATTACHMENT_MAX_FILE_BYTES) {
    return {
      ok: false,
      code: "attachment_limit_exceeded",
      message: `File exceeds the maximum size of ${ATTACHMENT_MAX_FILE_BYTES} bytes.`,
    };
  }
  const active = existing.filter(isActive);
  if (active.length >= ATTACHMENT_MAX_COUNT_PER_DRAFT) {
    return {
      ok: false,
      code: "attachment_limit_exceeded",
      message: `A draft can have at most ${ATTACHMENT_MAX_COUNT_PER_DRAFT} attachments.`,
    };
  }
  const activeTotal = active.reduce(
    (sum, record) => sum + record.size_bytes,
    0,
  );
  if (
    activeTotal + candidate.sizeBytes >
    ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT
  ) {
    return {
      ok: false,
      code: "attachment_limit_exceeded",
      message: `Attachments exceed the total limit of ${ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT} bytes per draft.`,
    };
  }
  return {
    ok: true,
    safeFilename: sanitizeFilename(candidate.originalFilename),
  };
}

/**
 * Deterministic storage object path inside the draft-attachments bucket.
 * The server returns the authoritative path; this mirrors its layout.
 */
export function buildStoragePath(
  workspaceId: string,
  draftId: string,
  attachmentId: string,
  safeFilename: string,
): string {
  return `${workspaceId}/${draftId}/${attachmentId}/${safeFilename}`;
}
