// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  ATTACHMENT_MAX_COUNT_PER_DRAFT,
  ATTACHMENT_MAX_FILE_BYTES,
  ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT,
} from "@/lib/phase2/contracts";
import {
  buildStoragePath,
  isAllowedMimeType,
  sanitizeFilename,
  validateAttachmentPlan,
} from "@/lib/attachments/validation";
import { deletedAttachment, readyAttachment } from "./fixtures";

const MIB = 1024 * 1024;

describe("isAllowedMimeType", () => {
  it.each(["application/pdf", "image/png", "image/jpeg", "text/plain"])(
    "allows %s",
    (mime) => {
      expect(isAllowedMimeType(mime)).toBe(true);
    },
  );

  it("compares case-insensitively but requires an exact type", () => {
    expect(isAllowedMimeType("Application/PDF")).toBe(true);
    expect(isAllowedMimeType("application/pdf; charset=utf-8")).toBe(false);
    expect(isAllowedMimeType(" application/pdf")).toBe(false);
  });

  it.each([
    "text/html",
    "image/svg+xml",
    "application/javascript",
    "text/javascript",
    "application/x-javascript",
    "application/zip",
    "application/x-msdownload",
    "application/octet-stream",
    "",
  ])("forbids %s", (mime) => {
    expect(isAllowedMimeType(mime)).toBe(false);
  });
});

describe("sanitizeFilename", () => {
  it("lowercases, transliterates umlauts/ß and preserves the extension", () => {
    expect(sanitizeFilename("Bericht Größe 2026.PDF")).toBe(
      "bericht-groesse-2026.pdf",
    );
  });

  it("is deterministic", () => {
    const name = "Bericht Größe 2026.PDF";
    expect(sanitizeFilename(name)).toBe(sanitizeFilename(name));
  });

  it("removes path separators from traversal attempts", () => {
    const safe = sanitizeFilename("../../etc/passwd");
    expect(safe).not.toContain("/");
    expect(safe).not.toContain("\\");
    expect(safe).not.toContain("..");
    expect(safe).toMatch(/^[a-z0-9._-]+$/);
    expect(safe).toBe("etc-passwd");
  });

  it("strips angle brackets and markup characters", () => {
    const safe = sanitizeFilename("<img src=x onerror=alert(1)>.png");
    expect(safe).not.toContain("<");
    expect(safe).not.toContain(">");
    expect(safe).toMatch(/^[a-z0-9._-]+$/);
    expect(safe.endsWith(".png")).toBe(true);
  });

  it("falls back for an Arabic filename while keeping the extension", () => {
    const safe = sanitizeFilename("تقرير المشروع.pdf");
    expect(safe).toMatch(/^[a-z0-9._-]+$/);
    expect(safe.endsWith(".pdf")).toBe(true);
    expect(safe.length).toBeGreaterThan(0);
  });

  it('returns "attachment" for empty and separator-only input', () => {
    expect(sanitizeFilename("")).toBe("attachment");
    expect(sanitizeFilename("   ")).toBe("attachment");
    expect(sanitizeFilename("...")).toBe("attachment");
    expect(sanitizeFilename("///")).toBe("attachment");
  });

  it("caps a 300-character name at 200 characters, keeping the extension", () => {
    const long = `${"a".repeat(296)}.pdf`;
    expect(long.length).toBe(300);
    const safe = sanitizeFilename(long);
    expect(safe.length).toBeLessThanOrEqual(200);
    expect(safe.endsWith(".pdf")).toBe(true);
    expect(safe).toMatch(/^[a-z0-9._-]+$/);
  });

  it("never returns an empty string", () => {
    for (const input of ["", ".", "-", "_", "؟؟؟", "<>", "́̂"]) {
      expect(sanitizeFilename(input).length).toBeGreaterThan(0);
    }
  });
});

describe("validateAttachmentPlan", () => {
  const candidate = (
    overrides: Partial<Parameters<typeof validateAttachmentPlan>[1]> = {},
  ) => ({
    originalFilename: "Bericht.pdf",
    mimeType: "application/pdf",
    sizeBytes: 1024,
    ...overrides,
  });

  it("accepts a valid candidate and returns the safe filename", () => {
    const result = validateAttachmentPlan([], candidate());
    expect(result).toEqual({ ok: true, safeFilename: "bericht.pdf" });
  });

  it("rejects forbidden types with attachment_type_forbidden", () => {
    for (const mimeType of ["text/html", "image/svg+xml", "application/zip"]) {
      const result = validateAttachmentPlan([], candidate({ mimeType }));
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.code).toBe("attachment_type_forbidden");
        expect(result.message.length).toBeGreaterThan(0);
      }
    }
  });

  it("rejects zero and negative sizes with invalid_body", () => {
    for (const sizeBytes of [0, -1]) {
      const result = validateAttachmentPlan([], candidate({ sizeBytes }));
      expect(result).toMatchObject({ ok: false, code: "invalid_body" });
    }
  });

  it("accepts exactly 10 MiB and rejects 10 MiB + 1", () => {
    expect(
      validateAttachmentPlan(
        [],
        candidate({ sizeBytes: ATTACHMENT_MAX_FILE_BYTES }),
      ).ok,
    ).toBe(true);
    expect(ATTACHMENT_MAX_FILE_BYTES).toBe(10 * MIB);
    const result = validateAttachmentPlan(
      [],
      candidate({ sizeBytes: ATTACHMENT_MAX_FILE_BYTES + 1 }),
    );
    expect(result).toMatchObject({
      ok: false,
      code: "attachment_limit_exceeded",
    });
  });

  it("rejects the 11th non-deleted attachment", () => {
    const existing = Array.from(
      { length: ATTACHMENT_MAX_COUNT_PER_DRAFT },
      (_, i) => readyAttachment({ id: `count-${i}`, size_bytes: 1 }),
    );
    const result = validateAttachmentPlan(existing, candidate());
    expect(result).toMatchObject({
      ok: false,
      code: "attachment_limit_exceeded",
    });
  });

  it("ignores deleted attachments for the count limit", () => {
    const existing = [
      ...Array.from({ length: ATTACHMENT_MAX_COUNT_PER_DRAFT - 1 }, (_, i) =>
        readyAttachment({ id: `count-${i}`, size_bytes: 1 }),
      ),
      deletedAttachment({ id: "deleted-1", size_bytes: 1 }),
    ];
    expect(validateAttachmentPlan(existing, candidate()).ok).toBe(true);
  });

  it("enforces the 25 MiB total including the candidate", () => {
    expect(ATTACHMENT_MAX_TOTAL_BYTES_PER_DRAFT).toBe(25 * MIB);
    const existing = [
      readyAttachment({ id: "big-1", size_bytes: 10 * MIB }),
      readyAttachment({ id: "big-2", size_bytes: 10 * MIB }),
    ];
    // 20 MiB existing + 5 MiB candidate = exactly 25 MiB: allowed.
    expect(
      validateAttachmentPlan(existing, candidate({ sizeBytes: 5 * MIB })).ok,
    ).toBe(true);
    // One byte more: rejected.
    const result = validateAttachmentPlan(
      existing,
      candidate({ sizeBytes: 5 * MIB + 1 }),
    );
    expect(result).toMatchObject({
      ok: false,
      code: "attachment_limit_exceeded",
    });
  });

  it("excludes deleted attachments from the total-size check", () => {
    const existing = [
      readyAttachment({ id: "big-1", size_bytes: 10 * MIB }),
      readyAttachment({ id: "big-2", size_bytes: 10 * MIB }),
      deletedAttachment({ id: "gone", size_bytes: 10 * MIB }),
    ];
    expect(
      validateAttachmentPlan(existing, candidate({ sizeBytes: 5 * MIB })).ok,
    ).toBe(true);
  });

  it("never echoes the filename in error messages", () => {
    const result = validateAttachmentPlan(
      [],
      candidate({
        originalFilename: "<script>secret.html</script>",
        mimeType: "text/html",
      }),
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.message).not.toContain("secret");
      expect(result.message).not.toContain("<");
    }
  });
});

describe("buildStoragePath", () => {
  it("joins workspace, draft, attachment id and safe filename", () => {
    expect(buildStoragePath("ws-1", "draft-2", "att-3", "report.pdf")).toBe(
      "ws-1/draft-2/att-3/report.pdf",
    );
  });
});
