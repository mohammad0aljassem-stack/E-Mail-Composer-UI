// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  DraftValidationError,
  validateDraftDocument,
  type DraftDocument,
} from "@/lib/composer/canonical";
import type { SignatureRecord } from "@/lib/phase2/contracts";
import {
  SIGNATURE_MARKER_TEXT,
  applySignature,
  containsSignatureBlock,
} from "@/lib/signatures/apply-signature";
import {
  signatureDocumentFromText,
  signatureTextFromDocument,
} from "@/lib/signatures/text-to-doc";
import { deepFreeze } from "../helpers";

function makeSignature(body_json: unknown): SignatureRecord {
  return {
    id: "sig-1",
    workspace_id: "ws-1",
    owner_user_id: "u-1",
    name: "Work",
    body_json: body_json as SignatureRecord["body_json"],
    is_default: true,
    created_at: "2026-07-11T00:00:00Z",
    updated_at: "2026-07-11T00:00:00Z",
  };
}

const signature = makeSignature({
  type: "doc",
  content: [
    {
      type: "paragraph",
      content: [{ type: "text", text: "Mohammad Al-Jassem" }],
    },
    {
      type: "paragraph",
      content: [{ type: "text", text: "Grüße aus Köln" }],
    },
  ],
});

const draft: DraftDocument = {
  type: "doc",
  content: [
    { type: "paragraph", content: [{ type: "text", text: "Hello there" }] },
  ],
};

describe("applySignature", () => {
  it('appends a separator, the "-- " marker, and the signature blocks', () => {
    const result = applySignature(draft, signature);
    expect(result.content).toEqual([
      { type: "paragraph", content: [{ type: "text", text: "Hello there" }] },
      { type: "paragraph" },
      { type: "paragraph", content: [{ type: "text", text: "-- " }] },
      {
        type: "paragraph",
        content: [{ type: "text", text: "Mohammad Al-Jassem" }],
      },
      {
        type: "paragraph",
        content: [{ type: "text", text: "Grüße aus Köln" }],
      },
    ]);
    expect(SIGNATURE_MARKER_TEXT).toBe("-- ");
    expect(validateDraftDocument(result).ok).toBe(true);
  });

  it("is idempotent by detection: second application returns the same document", () => {
    const once = applySignature(draft, signature);
    const twice = applySignature(once, signature);
    expect(twice).toBe(once);
    expect(JSON.stringify(twice)).toBe(JSON.stringify(once));
  });

  it("detects an existing signature tail via containsSignatureBlock", () => {
    expect(containsSignatureBlock(draft, signature)).toBe(false);
    const applied = applySignature(draft, signature);
    expect(containsSignatureBlock(applied, signature)).toBe(true);
  });

  it("appends a different signature even when another one is present", () => {
    const other = makeSignature({
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "Other" }] },
      ],
    });
    const applied = applySignature(draft, signature);
    const result = applySignature(applied, other);
    expect(result).not.toBe(applied);
    expect(JSON.stringify(result.content)).toContain("Other");
    expect(validateDraftDocument(result).ok).toBe(true);
  });

  it("rejects invalid signature bodies", () => {
    const invalid = makeSignature({
      type: "doc",
      content: [{ type: "image", attrs: { src: "https://evil.example" } }],
    });
    expect(() => applySignature(draft, invalid)).toThrow(DraftValidationError);
  });

  it("rejects invalid draft documents", () => {
    const invalidDraft = {
      type: "doc",
      content: [{ type: "iframe" }],
    } as unknown as DraftDocument;
    expect(() => applySignature(invalidDraft, signature)).toThrow(
      DraftValidationError,
    );
  });

  it("never mutates its inputs", () => {
    const frozenDraft = deepFreeze({
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "Frozen" }] },
      ],
    }) as DraftDocument;
    const frozenSignature = deepFreeze(
      makeSignature({
        type: "doc",
        content: [
          { type: "paragraph", content: [{ type: "text", text: "Sig" }] },
        ],
      }),
    );
    const result = applySignature(frozenDraft, frozenSignature);
    expect(validateDraftDocument(result).ok).toBe(true);
    // And applying again on the frozen result is a no-op.
    expect(applySignature(deepFreeze(result), frozenSignature)).toBe(result);
  });

  it("is deterministic across runs", () => {
    const a = applySignature(draft, signature);
    const b = applySignature(draft, signature);
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });
});

describe("signature text round-trip helpers", () => {
  it("splits textarea text into canonical paragraphs", () => {
    const doc = signatureDocumentFromText("Line one\n\nZeile drei äöü");
    expect(doc).toEqual({
      type: "doc",
      content: [
        { type: "paragraph", content: [{ type: "text", text: "Line one" }] },
        { type: "paragraph" },
        {
          type: "paragraph",
          content: [{ type: "text", text: "Zeile drei äöü" }],
        },
      ],
    });
    expect(validateDraftDocument(doc).ok).toBe(true);
  });

  it("produces a valid empty document from empty text", () => {
    const doc = signatureDocumentFromText("");
    expect(validateDraftDocument(doc).ok).toBe(true);
  });

  it("round-trips text produced by the builder", () => {
    const text = "الاسم الكامل\nGrüße\n\nTeam";
    expect(signatureTextFromDocument(signatureDocumentFromText(text))).toBe(
      text,
    );
  });
});
