// @vitest-environment node

import { describe, expect, it } from "vitest";
import { createSampleDraftDocument } from "@/lib/composer/samples";
import { renderDraft } from "@/server/render/renderDraft";
import { renderDraftPackage } from "@/server/render/renderDraftPackage";
import { buildAttachmentManifest } from "@/lib/attachments/manifest";
import {
  deletedAttachment,
  failedAttachment,
  pendingAttachment,
  readyAttachment,
} from "./fixtures";

describe("renderDraftPackage", () => {
  it("returns the plain renderDraft output untouched when there are no attachments", async () => {
    const plain = await renderDraft(createSampleDraftDocument());
    const pkg = await renderDraftPackage(createSampleDraftDocument(), []);
    expect(pkg.html).toBe(plain.html);
    expect(pkg.text).toBe(plain.text);
    expect(pkg.attachments).toEqual([]);
  });

  it("never alters the sanitized html, even with ready attachments", async () => {
    const plain = await renderDraft(createSampleDraftDocument());
    const pkg = await renderDraftPackage(createSampleDraftDocument(), [
      readyAttachment({ safe_filename: "bericht.pdf" }),
    ]);
    expect(pkg.html).toBe(plain.html);
  });

  it("adds a text attachment section only when ready attachments exist", async () => {
    const withoutReady = await renderDraftPackage(createSampleDraftDocument(), [
      pendingAttachment({ safe_filename: "pending-only.pdf" }),
    ]);
    expect(withoutReady.text).not.toContain("Anlagen:");

    const withReady = await renderDraftPackage(createSampleDraftDocument(), [
      readyAttachment({
        safe_filename: "bericht.pdf",
        mime_type: "application/pdf",
        size_bytes: 2048,
      }),
    ]);
    expect(withReady.text).toContain("Anlagen:");
    expect(withReady.text).toContain(
      "- bericht.pdf (application/pdf, 2048 bytes)",
    );
  });

  it("never mentions pending, failed or deleted filenames in the text", async () => {
    const pkg = await renderDraftPackage(createSampleDraftDocument(), [
      readyAttachment({ safe_filename: "ready-file.pdf" }),
      pendingAttachment({ safe_filename: "pending-file.pdf" }),
      failedAttachment({ safe_filename: "failed-file.pdf" }),
      deletedAttachment({ safe_filename: "deleted-file.pdf" }),
      readyAttachment({
        id: "unverified",
        safe_filename: "unverified-file.pdf",
        verified_at: null,
      }),
    ]);
    expect(pkg.text).toContain("ready-file.pdf");
    expect(pkg.text).not.toContain("pending-file.pdf");
    expect(pkg.text).not.toContain("failed-file.pdf");
    expect(pkg.text).not.toContain("deleted-file.pdf");
    expect(pkg.text).not.toContain("unverified-file.pdf");
  });

  it("exposes exactly the buildAttachmentManifest result", async () => {
    const records = [
      readyAttachment({ id: "r-2", created_at: "2026-07-01T11:00:00.000Z" }),
      readyAttachment({ id: "r-1", created_at: "2026-07-01T09:00:00.000Z" }),
      pendingAttachment({ id: "p-1" }),
    ];
    const pkg = await renderDraftPackage(createSampleDraftDocument(), records);
    expect(pkg.attachments).toEqual(buildAttachmentManifest(records));
    expect(pkg.attachments.map((item) => item.attachmentId)).toEqual([
      "r-1",
      "r-2",
    ]);
  });

  it("is deterministic across two runs", async () => {
    const records = () => [
      readyAttachment({ id: "d-1", safe_filename: "eins.pdf" }),
      readyAttachment({ id: "d-2", safe_filename: "zwei.png" }),
    ];
    const first = await renderDraftPackage(
      createSampleDraftDocument(),
      records(),
    );
    const second = await renderDraftPackage(
      createSampleDraftDocument(),
      records(),
    );
    expect(second.html).toBe(first.html);
    expect(second.text).toBe(first.text);
    expect(second.attachments).toEqual(first.attachments);
  });

  it("keeps a malicious ready filename out of the html entirely", async () => {
    const malicious = "<script>alert(1)</script>.pdf";
    const pkg = await renderDraftPackage(createSampleDraftDocument(), [
      readyAttachment({ safe_filename: malicious }),
    ]);
    // Plain text may carry it (text cannot execute) ...
    expect(pkg.text).toContain(malicious);
    // ... but the sanitized html never contains it in any form.
    expect(pkg.html).not.toContain(malicious);
    expect(pkg.html).not.toContain("alert(1)");
  });

  it("rejects invalid documents like renderDraft does", async () => {
    await expect(
      renderDraftPackage({ type: "doc", content: [{ type: "image" }] }, []),
    ).rejects.toThrow(/Invalid draft document/);
  });
});
