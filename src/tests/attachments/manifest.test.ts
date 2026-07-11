// @vitest-environment node

import { describe, expect, it } from "vitest";
import { ATTACHMENT_BUCKET } from "@/lib/phase2/contracts";
import { buildAttachmentManifest } from "@/lib/attachments/manifest";
import {
  deletedAttachment,
  failedAttachment,
  makeAttachment,
  pendingAttachment,
  readyAttachment,
} from "./fixtures";

describe("buildAttachmentManifest", () => {
  it("includes only ready attachments that are verified and not deleted", () => {
    const ready = readyAttachment({ id: "ready-1" });
    const manifest = buildAttachmentManifest([
      ready,
      pendingAttachment({ id: "pending-1" }),
      failedAttachment({ id: "failed-1" }),
      deletedAttachment({ id: "deleted-1" }),
    ]);
    expect(manifest).toHaveLength(1);
    expect(manifest[0]?.attachmentId).toBe("ready-1");
  });

  it("excludes ready rows without verified_at", () => {
    const manifest = buildAttachmentManifest([
      readyAttachment({ id: "unverified", verified_at: null }),
    ]);
    expect(manifest).toEqual([]);
  });

  it("excludes ready rows with deleted_at set", () => {
    const manifest = buildAttachmentManifest([
      readyAttachment({
        id: "soft-deleted",
        deleted_at: "2026-07-03T00:00:00.000Z",
      }),
    ]);
    expect(manifest).toEqual([]);
  });

  it("returns an empty manifest for an empty input", () => {
    expect(buildAttachmentManifest([])).toEqual([]);
  });

  it("maps every field exactly", () => {
    const record = readyAttachment({
      id: "att-map",
      storage_bucket: ATTACHMENT_BUCKET,
      storage_path: "ws-1/draft-1/att-map/report.pdf",
      safe_filename: "report.pdf",
      mime_type: "application/pdf",
      size_bytes: 2048,
      sha256: "abc123",
    });
    expect(buildAttachmentManifest([record])).toEqual([
      {
        attachmentId: "att-map",
        bucket: ATTACHMENT_BUCKET,
        path: "ws-1/draft-1/att-map/report.pdf",
        filename: "report.pdf",
        contentType: "application/pdf",
        sizeBytes: 2048,
        sha256: "abc123",
      },
    ]);
  });

  it("orders deterministically by created_at, then id", () => {
    const a = readyAttachment({
      id: "b-later-id",
      created_at: "2026-07-01T09:00:00.000Z",
    });
    const b = readyAttachment({
      id: "a-earlier-id",
      created_at: "2026-07-01T09:00:00.000Z",
    });
    const c = readyAttachment({
      id: "z-first-created",
      created_at: "2026-07-01T08:00:00.000Z",
    });
    const expectedOrder = ["z-first-created", "a-earlier-id", "b-later-id"];
    const first = buildAttachmentManifest([a, b, c]);
    const second = buildAttachmentManifest([c, a, b]);
    expect(first.map((item) => item.attachmentId)).toEqual(expectedOrder);
    expect(second).toEqual(first);
  });

  it("does not mutate the input array", () => {
    const records = [
      readyAttachment({ id: "m-2", created_at: "2026-07-01T10:00:00.000Z" }),
      readyAttachment({ id: "m-1", created_at: "2026-07-01T09:00:00.000Z" }),
    ];
    const snapshot = records.map((record) => record.id);
    buildAttachmentManifest(records);
    expect(records.map((record) => record.id)).toEqual(snapshot);
  });

  it("never invents entries for unknown statuses", () => {
    const weird = makeAttachment({
      id: "weird",
      status: "pending",
      verified_at: "2026-07-01T10:00:00.000Z",
    });
    expect(buildAttachmentManifest([weird])).toEqual([]);
  });
});
