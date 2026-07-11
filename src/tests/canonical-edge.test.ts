// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  DraftValidationError,
  normalizeDraftDocument,
  validateDraftDocument,
} from "@/lib/composer/canonical";

/**
 * Exhaustive coverage of the validation error branches and normalization
 * edge cases. Each case asserts the specific structural reason so a
 * regression that silently accepts bad input is caught.
 */

function firstError(input: unknown): string {
  const result = validateDraftDocument(input);
  expect(result.ok).toBe(false);
  return result.ok ? "" : result.errors.join(" | ");
}

function para(content: unknown): unknown {
  return { type: "paragraph", content };
}

function docWith(block: unknown): unknown {
  return { type: "doc", content: [block] };
}

describe("mark validation branches", () => {
  it("rejects marks that are not an array", () => {
    expect(
      firstError(docWith(para([{ type: "text", text: "x", marks: {} }]))),
    ).toContain("marks must be an array");
  });

  it("rejects marks that are not objects", () => {
    expect(
      firstError(docWith(para([{ type: "text", text: "x", marks: ["bold"] }]))),
    ).toContain("mark must be an object");
  });

  it("rejects mark types that are not strings", () => {
    expect(
      firstError(
        docWith(para([{ type: "text", text: "x", marks: [{ type: 7 }] }])),
      ),
    ).toContain("unsupported mark type 7");
  });

  it("rejects link marks without an attrs object", () => {
    expect(
      firstError(
        docWith(para([{ type: "text", text: "x", marks: [{ type: "link" }] }])),
      ),
    ).toContain("link mark requires attrs");
  });

  it("rejects bold/italic marks that carry attrs", () => {
    expect(
      firstError(
        docWith(
          para([
            { type: "text", text: "x", marks: [{ type: "bold", attrs: {} }] },
          ]),
        ),
      ),
    ).toContain('mark "bold" must not have attrs');
  });
});

describe("inline node validation branches", () => {
  it("rejects inline nodes that are not objects", () => {
    expect(firstError(docWith(para(["plain string"])))).toContain(
      "node must be an object",
    );
  });

  it("rejects empty text nodes", () => {
    expect(firstError(docWith(para([{ type: "text", text: "" }])))).toContain(
      "text node requires a non-empty string text",
    );
  });

  it("accepts a hardBreak carrying a valid mark", () => {
    expect(
      validateDraftDocument(
        docWith(
          para([
            { type: "text", text: "x" },
            { type: "hardBreak", marks: [{ type: "bold" }] },
          ]),
        ),
      ).ok,
    ).toBe(true);
  });

  it("rejects unsupported inline node types", () => {
    expect(firstError(docWith(para([{ type: "mention", id: 1 }])))).toContain(
      'unsupported node type "mention"',
    );
  });
});

describe("paragraph validation branches", () => {
  it("rejects a paragraph whose content is an empty array", () => {
    expect(firstError(docWith(para([])))).toContain(
      "paragraph content, when present, must be non-empty",
    );
  });
});

describe("list validation branches", () => {
  it("rejects a bulletList with empty content", () => {
    expect(firstError(docWith({ type: "bulletList", content: [] }))).toContain(
      "bulletList requires non-empty content",
    );
  });

  it("rejects list items that are not objects", () => {
    expect(
      firstError(docWith({ type: "bulletList", content: ["x"] })),
    ).toContain("node must be an object");
  });

  it("rejects a list child that is not a listItem", () => {
    expect(
      firstError(
        docWith({ type: "bulletList", content: [{ type: "paragraph" }] }),
      ),
    ).toContain('expected "listItem"');
  });

  it("rejects a listItem with empty content", () => {
    expect(
      firstError(
        docWith({
          type: "bulletList",
          content: [{ type: "listItem", content: [] }],
        }),
      ),
    ).toContain("listItem requires non-empty content");
  });

  it("rejects a listItem child that is not an object", () => {
    expect(
      firstError(
        docWith({
          type: "bulletList",
          content: [{ type: "listItem", content: ["x"] }],
        }),
      ),
    ).toContain("node must be an object");
  });

  it("rejects unsupported node types inside a listItem", () => {
    expect(
      firstError(
        docWith({
          type: "bulletList",
          content: [
            {
              type: "listItem",
              content: [
                para([{ type: "text", text: "x" }]),
                { type: "image", attrs: { src: "x" } },
              ],
            },
          ],
        }),
      ),
    ).toContain("inside listItem");
  });

  it("rejects an orderedList with empty content", () => {
    expect(firstError(docWith({ type: "orderedList", content: [] }))).toContain(
      "orderedList requires non-empty content",
    );
  });

  it("rejects orderedList attrs that are not an object", () => {
    expect(
      firstError(docWith({ type: "orderedList", attrs: 5, content: [] })),
    ).toContain("orderedList attrs must be an object");
  });

  it("rejects a non-positive orderedList start", () => {
    expect(
      firstError(
        docWith({
          type: "orderedList",
          attrs: { start: 0 },
          content: [
            {
              type: "listItem",
              content: [para([{ type: "text", text: "x" }])],
            },
          ],
        }),
      ),
    ).toContain("orderedList start must be a positive integer");
  });

  it("rejects an orderedList type attribute that is not null", () => {
    expect(
      firstError(
        docWith({
          type: "orderedList",
          attrs: { type: "a" },
          content: [
            {
              type: "listItem",
              content: [para([{ type: "text", text: "x" }])],
            },
          ],
        }),
      ),
    ).toContain("orderedList type attribute must be null");
  });
});

describe("blockquote validation branches", () => {
  it("rejects a blockquote with empty content", () => {
    expect(firstError(docWith({ type: "blockquote", content: [] }))).toContain(
      "blockquote requires non-empty content",
    );
  });

  it("rejects a block that is not an object", () => {
    expect(firstError({ type: "doc", content: ["x"] })).toContain(
      "node must be an object",
    );
  });
});

describe("normalization edge cases", () => {
  it("keeps a hardBreak that has no marks", () => {
    const normalized = normalizeDraftDocument(
      docWith(
        para([
          { type: "text", text: "a" },
          { type: "hardBreak" },
          { type: "text", text: "b" },
        ]),
      ),
    );
    expect(JSON.stringify(normalized)).toContain("hardBreak");
  });

  it("drops link marks whose attrs is not an object, keeping the text", () => {
    const normalized = normalizeDraftDocument(
      docWith(
        para([{ type: "text", text: "label", marks: [{ type: "link" }] }]),
      ),
    );
    expect(JSON.stringify(normalized)).toContain("label");
    expect(JSON.stringify(normalized)).not.toContain("link");
  });

  it("throws when normalizing an unsupported inline node", () => {
    expect(() =>
      normalizeDraftDocument(docWith(para([{ type: "mention", id: 1 }]))),
    ).toThrow(DraftValidationError);
  });

  it("throws when normalizing an unsupported block node", () => {
    expect(() =>
      normalizeDraftDocument(docWith({ type: "callout", content: [] })),
    ).toThrow(DraftValidationError);
  });

  it("throws when normalizing a blockquote with unsupported children", () => {
    expect(() =>
      normalizeDraftDocument(
        docWith({ type: "blockquote", content: [{ type: "image" }] }),
      ),
    ).toThrow(DraftValidationError);
  });

  it("throws when a bulletList contains a non-listItem after normalization", () => {
    expect(() =>
      normalizeDraftDocument(
        docWith({ type: "bulletList", content: [{ type: "paragraph" }] }),
      ),
    ).toThrow(DraftValidationError);
  });

  it("throws for a null document", () => {
    expect(() => normalizeDraftDocument(null)).toThrow(
      /document must be an object/,
    );
  });

  it("throws for a plain object that is not a doc", () => {
    expect(() => normalizeDraftDocument({ type: "paragraph" })).toThrow(
      /root node type must be "doc"/,
    );
  });

  it("caps the number of reported errors", () => {
    const many = Array.from({ length: 40 }, () => ({ type: "image" }));
    const result = validateDraftDocument({ type: "doc", content: many });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.length).toBeLessThanOrEqual(20);
    }
  });
});
