// @vitest-environment node

import { describe, expect, it, vi } from "vitest";
import { ATTACHMENT_BUCKET } from "@/lib/phase2/contracts";
import {
  AttachmentClientError,
  createAttachmentIntent,
  deleteAttachment,
  finalizeAttachment,
  listAttachments,
  uploadAttachmentObject,
  type SupabaseStorageLike,
} from "@/lib/attachments/client";
import { pendingAttachment, readyAttachment } from "./fixtures";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("attachment api client", () => {
  it("creates an intent via POST and returns attachment + uploadPath", async () => {
    const attachment = pendingAttachment({ id: "att-1" });
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(jsonResponse({ attachment, uploadPath: "p/a/t/h" }));
    const result = await createAttachmentIntent(
      "ws-1",
      "draft-1",
      {
        originalFilename: "a.pdf",
        mimeType: "application/pdf",
        sizeBytes: 10,
      },
      { fetchImpl },
    );
    expect(result.uploadPath).toBe("p/a/t/h");
    expect(result.attachment.id).toBe("att-1");
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/workspaces/ws-1/drafts/draft-1/attachments");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({
      originalFilename: "a.pdf",
      mimeType: "application/pdf",
      sizeBytes: 10,
    });
  });

  it("encodes path segments", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(jsonResponse({ attachments: [] }));
    await listAttachments("ws/1", "draft 2", { fetchImpl });
    const [url] = fetchImpl.mock.calls[0] as [string];
    expect(url).toBe("/api/workspaces/ws%2F1/drafts/draft%202/attachments");
  });

  it("finalizes via the finalize route", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(jsonResponse({ attachment: readyAttachment() }));
    await finalizeAttachment(
      "ws-1",
      "draft-1",
      "att-9",
      { sha256: "abc" },
      { fetchImpl },
    );
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(
      "/api/workspaces/ws-1/drafts/draft-1/attachments/att-9/finalize",
    );
    expect(init.method).toBe("POST");
  });

  it("maps structured ApiError responses to AttachmentClientError", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(
      jsonResponse(
        {
          error: {
            code: "attachment_not_verified",
            message: "Object missing.",
          },
        },
        422,
      ),
    );
    const promise = finalizeAttachment(
      "ws-1",
      "draft-1",
      "att-9",
      {},
      {
        fetchImpl,
      },
    );
    await expect(promise).rejects.toMatchObject({
      name: "AttachmentClientError",
      code: "attachment_not_verified",
      status: 422,
    });
  });

  it("maps unstructured failures to internal_error without leaking bodies", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(new Response("<html>boom</html>", { status: 502 }));
    const error = await deleteAttachment("ws-1", "draft-1", "att-9", {
      fetchImpl,
    }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(AttachmentClientError);
    if (error instanceof AttachmentClientError) {
      expect(error.code).toBe("internal_error");
      expect(error.status).toBe(502);
      expect(error.message).not.toContain("boom");
    }
  });

  it("passes the abort signal through", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(jsonResponse({ attachments: [] }));
    const controller = new AbortController();
    await listAttachments("ws-1", "draft-1", {
      fetchImpl,
      signal: controller.signal,
    });
    const [, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect(init.signal).toBe(controller.signal);
  });
});

describe("uploadAttachmentObject", () => {
  function stubClient(result: {
    data: { path: string } | null;
    error: { message: string } | null;
  }) {
    const upload = vi.fn().mockResolvedValue(result);
    const from = vi.fn().mockReturnValue({ upload });
    const client: SupabaseStorageLike = { storage: { from } };
    return { client, from, upload };
  }

  it("uploads to the draft-attachments bucket at the exact path, never upserting", async () => {
    const { client, from, upload } = stubClient({
      data: { path: "ws-1/draft-1/att-1/a.pdf" },
      error: null,
    });
    const file = new Blob(["%PDF"], { type: "application/pdf" });
    const result = await uploadAttachmentObject(
      client,
      "ws-1/draft-1/att-1/a.pdf",
      file,
    );
    expect(result.path).toBe("ws-1/draft-1/att-1/a.pdf");
    expect(from).toHaveBeenCalledWith(ATTACHMENT_BUCKET);
    expect(upload).toHaveBeenCalledWith("ws-1/draft-1/att-1/a.pdf", file, {
      upsert: false,
      contentType: "application/pdf",
    });
  });

  it("throws a structured error when the storage upload fails", async () => {
    const { client } = stubClient({
      data: null,
      error: { message: "Duplicate object" },
    });
    await expect(
      uploadAttachmentObject(
        client,
        "ws-1/draft-1/att-1/a.pdf",
        new Blob(["x"], { type: "application/pdf" }),
      ),
    ).rejects.toBeInstanceOf(AttachmentClientError);
  });
});
