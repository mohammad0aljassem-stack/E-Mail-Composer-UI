// @vitest-environment node

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { GET, POST } from "@/app/api/composer/render/route";
import { createSampleDraftDocument } from "@/lib/composer/samples";

const URL_ = "http://localhost/api/composer/render";

function jsonRequest(body: unknown, contentType = "application/json"): Request {
  return new Request(URL_, {
    method: "POST",
    headers: { "content-type": contentType },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const originalFlag = process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED;

beforeEach(() => {
  process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED = "true";
});

afterEach(() => {
  process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED = originalFlag;
});

describe("POST /api/composer/render", () => {
  it("returns html and text for a valid canonical document", async () => {
    const response = await POST(
      jsonRequest({ document: createSampleDraftDocument() }),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as { html: string; text: string };
    expect(body.html).toContain("Grüße");
    expect(body.html.toLowerCase()).toMatch(/^<!doctype/);
    expect(body.text).toContain("Sehr geehrte Damen und Herren,");
  });

  it("rejects non-JSON content types", async () => {
    const response = await POST(jsonRequest("x=1", "text/plain"));
    expect(response.status).toBe(415);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("unsupported_media_type");
  });

  it("rejects bodies that are not valid JSON", async () => {
    const response = await POST(jsonRequest("{not json"));
    expect(response.status).toBe(400);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("invalid_json");
  });

  it("rejects JSON without a document property", async () => {
    const response = await POST(jsonRequest({ nope: true }));
    expect(response.status).toBe(400);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("missing_document");
  });

  it("rejects invalid canonical documents with structured details", async () => {
    const response = await POST(
      jsonRequest({ document: { type: "doc", content: [{ type: "image" }] } }),
    );
    expect(response.status).toBe(422);
    const body = (await response.json()) as {
      error: { code: string; details?: string[] };
    };
    expect(body.error.code).toBe("invalid_document");
    expect(body.error.details?.join(" ")).toContain("image");
  });

  it("rejects oversized requests", async () => {
    const bigText = "a".repeat(300 * 1024);
    const response = await POST(
      jsonRequest({
        document: {
          type: "doc",
          content: [
            { type: "paragraph", content: [{ type: "text", text: bigText }] },
          ],
        },
      }),
    );
    expect(response.status).toBe(413);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("payload_too_large");
  });

  it("never exposes stack traces in error responses", async () => {
    const responses = await Promise.all([
      POST(jsonRequest("{broken", "application/json")),
      POST(
        jsonRequest({ document: { type: "doc", content: [{ type: "x" }] } }),
      ),
      POST(jsonRequest("x", "text/plain")),
    ]);
    for (const response of responses) {
      const raw = await response.text();
      expect(raw).not.toMatch(/\n\s+at /);
      expect(raw).not.toContain("stack");
      const parsed = JSON.parse(raw) as { error: Record<string, unknown> };
      expect(Object.keys(parsed.error).sort()).toEqual(
        expect.arrayContaining(["code", "message"]),
      );
    }
  });

  it("returns 404 when the feature flag is disabled", async () => {
    process.env.NEXT_PUBLIC_COMPOSER_V1_ENABLED = "false";
    const response = await POST(
      jsonRequest({ document: createSampleDraftDocument() }),
    );
    expect(response.status).toBe(404);
  });

  it("rejects GET requests", async () => {
    const response = GET();
    expect(response.status).toBe(405);
  });
});
