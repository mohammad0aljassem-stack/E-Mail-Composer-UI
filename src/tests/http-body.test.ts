// @vitest-environment node

import { describe, expect, it, vi } from "vitest";
import { readJsonBodyWithLimit } from "@/lib/http/body";

const LIMIT = 1024;

function jsonRequest(body: BodyInit, contentType = "application/json") {
  return new Request("http://localhost/test", {
    method: "POST",
    headers: { "content-type": contentType },
    body,
    // @ts-expect-error duplex is required by undici for streaming bodies
    duplex: "half",
  });
}

function chunkedRequest(
  chunks: Uint8Array[],
  contentType = "application/json",
) {
  let index = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (index < chunks.length) {
        controller.enqueue(chunks[index]);
        index += 1;
      } else {
        controller.close();
      }
    },
  });
  return jsonRequest(stream, contentType);
}

describe("readJsonBodyWithLimit", () => {
  it("parses a small JSON body", async () => {
    const result = await readJsonBodyWithLimit(
      jsonRequest(JSON.stringify({ ok: true })),
      LIMIT,
    );
    expect(result).toEqual({ ok: true, value: { ok: true } });
  });

  it("rejects non-JSON content types with 415", async () => {
    const result = await readJsonBodyWithLimit(
      jsonRequest("{}", "text/plain"),
      LIMIT,
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.status).toBe(415);
      expect(result.code).toBe("unsupported_media_type");
    }
  });

  it("rejects an oversized declared Content-Length before reading", async () => {
    const request = new Request("http://localhost/test", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": String(LIMIT + 1),
      },
      body: "x",
    });
    const result = await readJsonBodyWithLimit(request, LIMIT);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.status).toBe(413);
      expect(result.code).toBe("payload_too_large");
    }
  });

  it("stops a chunked oversized body early and cancels the stream", async () => {
    const encoder = new TextEncoder();
    const chunk = encoder.encode("a".repeat(512));
    let pulls = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        controller.enqueue(chunk);
        // endless stream — the reader must stop on its own
      },
    });
    const result = await readJsonBodyWithLimit(jsonRequest(stream), LIMIT);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.status).toBe(413);
      expect(result.code).toBe("payload_too_large");
    }
    // The limit is 1024 = 2 chunks; a third pull may occur due to readahead,
    // but the stream must not have been drained much beyond the limit.
    expect(pulls).toBeLessThanOrEqual(4);
  });

  it("enforces the real byte count when Content-Length is absent", async () => {
    const encoder = new TextEncoder();
    const chunks = [
      encoder.encode('{"filler":"'),
      encoder.encode("b".repeat(2048)),
      encoder.encode('"}'),
    ];
    const result = await readJsonBodyWithLimit(chunkedRequest(chunks), LIMIT);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.status).toBe(413);
    }
  });

  it("handles multi-byte UTF-8 split across chunk boundaries", async () => {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(JSON.stringify({ text: "Grüße مرحبا" }));
    const mid = 9; // split inside a multi-byte sequence
    const result = await readJsonBodyWithLimit(
      chunkedRequest([bytes.slice(0, mid), bytes.slice(mid)]),
      LIMIT,
    );
    expect(result).toEqual({ ok: true, value: { text: "Grüße مرحبا" } });
  });

  it("returns invalid_json for malformed bodies without throwing", async () => {
    const result = await readJsonBodyWithLimit(jsonRequest("{nope"), LIMIT);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.status).toBe(400);
      expect(result.code).toBe("invalid_json");
    }
  });

  it("handles malformed UTF-8 bytes without throwing", async () => {
    const bad = new Uint8Array([0x22, 0xff, 0xfe, 0x22]); // "<invalid>"
    const result = await readJsonBodyWithLimit(chunkedRequest([bad]), LIMIT);
    // Lenient decoding turns invalid bytes into U+FFFD; the JSON string
    // parses (or fails) without ever throwing out of the reader.
    expect(typeof result.ok).toBe("boolean");
  });

  it("never calls console methods (no content logging)", async () => {
    const spy = vi.spyOn(console, "log");
    const spyErr = vi.spyOn(console, "error");
    await readJsonBodyWithLimit(
      jsonRequest(JSON.stringify({ secret: "GEHEIM" })),
      LIMIT,
    );
    expect(spy).not.toHaveBeenCalled();
    expect(spyErr).not.toHaveBeenCalled();
    spy.mockRestore();
    spyErr.mockRestore();
  });
});
