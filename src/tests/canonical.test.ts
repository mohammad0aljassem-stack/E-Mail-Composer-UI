// @vitest-environment node

import { describe, expect, it } from "vitest";
import {
  DraftValidationError,
  createEmptyDraftDocument,
  normalizeDraftDocument,
  validateDraftDocument,
  type DraftDocument,
} from "@/lib/composer/canonical";
import { createSampleDraftDocument } from "@/lib/composer/samples";
import { deepFreeze } from "./helpers";

describe("createEmptyDraftDocument", () => {
  it("returns a canonical empty document", () => {
    expect(createEmptyDraftDocument()).toEqual({
      type: "doc",
      content: [{ type: "paragraph" }],
    });
  });

  it("returns a fresh object on every call", () => {
    const a = createEmptyDraftDocument();
    const b = createEmptyDraftDocument();
    expect(a).not.toBe(b);
    expect(a.content).not.toBe(b.content);
  });
});

describe("validateDraftDocument", () => {
  it("accepts a valid document with all allowed nodes and marks", () => {
    const result = validateDraftDocument(createSampleDraftDocument());
    expect(result.ok).toBe(true);
  });

  it("rejects invalid roots", () => {
    for (const input of [
      null,
      undefined,
      [],
      "doc",
      42,
      { type: "paragraph" },
    ]) {
      const result = validateDraftDocument(input);
      expect(result.ok).toBe(false);
    }
  });

  it("rejects documents with empty content", () => {
    expect(validateDraftDocument({ type: "doc", content: [] }).ok).toBe(false);
    expect(validateDraftDocument({ type: "doc" }).ok).toBe(false);
  });

  it("rejects unsupported node types (image, table, iframe, rawHtml)", () => {
    for (const type of ["image", "table", "iframe", "rawHtml", "video"]) {
      const result = validateDraftDocument({
        type: "doc",
        content: [{ type }],
      });
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.errors.join(" ")).toContain(
          `unsupported node type "${type}"`,
        );
      }
    }
  });

  it("rejects unsupported nested content instead of passing it silently", () => {
    const result = validateDraftDocument({
      type: "doc",
      content: [
        {
          type: "blockquote",
          content: [{ type: "iframe", attrs: { src: "https://evil.example" } }],
        },
      ],
    });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.join(" ")).toContain("iframe");
    }
  });

  it("rejects unsupported marks", () => {
    const result = validateDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            { type: "text", text: "x", marks: [{ type: "underline" }] },
          ],
        },
      ],
    });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors.join(" ")).toContain(
        'unsupported mark type "underline"',
      );
    }
  });

  it("rejects unknown keys and attributes", () => {
    expect(
      validateDraftDocument({
        type: "doc",
        content: [{ type: "paragraph", style: "color:red" }],
      }).ok,
    ).toBe(false);
    expect(
      validateDraftDocument({
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "x",
                marks: [
                  {
                    type: "link",
                    attrs: { href: "https://a.example/", onclick: "x" },
                  },
                ],
              },
            ],
          },
        ],
      }).ok,
    ).toBe(false);
  });

  it("rejects unsafe link hrefs", () => {
    for (const href of [
      "javascript:alert(1)",
      "data:text/html,x",
      "//protocol.relative",
      "vbscript:x",
    ]) {
      const result = validateDraftDocument({
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "x",
                marks: [{ type: "link", attrs: { href } }],
              },
            ],
          },
        ],
      });
      expect(result.ok).toBe(false);
    }
  });

  it("rejects list items that do not start with a paragraph", () => {
    const result = validateDraftDocument({
      type: "doc",
      content: [
        {
          type: "bulletList",
          content: [
            {
              type: "listItem",
              content: [{ type: "bulletList", content: [] }],
            },
          ],
        },
      ],
    });
    expect(result.ok).toBe(false);
  });

  it("rejects excessive nesting", () => {
    let node: Record<string, unknown> = { type: "paragraph" };
    for (let i = 0; i < 30; i += 1) {
      node = { type: "blockquote", content: [node] };
    }
    const result = validateDraftDocument({ type: "doc", content: [node] });
    expect(result.ok).toBe(false);
  });
});

describe("normalizeDraftDocument", () => {
  it("is deterministic", () => {
    const a = normalizeDraftDocument(createSampleDraftDocument());
    const b = normalizeDraftDocument(createSampleDraftDocument());
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });

  it("is idempotent", () => {
    const once = normalizeDraftDocument(createSampleDraftDocument());
    const twice = normalizeDraftDocument(once);
    expect(JSON.stringify(twice)).toBe(JSON.stringify(once));
  });

  it("does not mutate its input", () => {
    const input = deepFreeze(createSampleDraftDocument());
    expect(() => normalizeDraftDocument(input)).not.toThrow();
    expect(input).toEqual(createSampleDraftDocument());
  });

  it("drops Tiptap default attributes from ordered lists", () => {
    const normalized = normalizeDraftDocument({
      type: "doc",
      content: [
        {
          type: "orderedList",
          attrs: { start: 1, type: null },
          content: [
            {
              type: "listItem",
              content: [
                { type: "paragraph", content: [{ type: "text", text: "x" }] },
              ],
            },
          ],
        },
      ],
    });
    const list = normalized.content[0];
    expect(list).toBeDefined();
    expect("attrs" in (list as object)).toBe(false);
  });

  it("keeps a non-default ordered list start", () => {
    const normalized = normalizeDraftDocument({
      type: "doc",
      content: [
        {
          type: "orderedList",
          attrs: { start: 4, type: null },
          content: [
            {
              type: "listItem",
              content: [
                { type: "paragraph", content: [{ type: "text", text: "x" }] },
              ],
            },
          ],
        },
      ],
    });
    expect(normalized.content[0]).toMatchObject({ attrs: { start: 4 } });
  });

  it("removes link marks with unsafe hrefs but keeps the text", () => {
    const normalized = normalizeDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: "click me",
              marks: [{ type: "link", attrs: { href: "javascript:alert(1)" } }],
            },
          ],
        },
      ],
    });
    expect(JSON.stringify(normalized)).not.toContain("javascript");
    expect(JSON.stringify(normalized)).toContain("click me");
  });

  it("drops presentational link attributes (target, rel, class)", () => {
    const normalized = normalizeDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: "docs",
              marks: [
                {
                  type: "link",
                  attrs: {
                    href: "https://example.com/",
                    target: "_blank",
                    rel: "noopener",
                    class: "fancy",
                  },
                },
              ],
            },
          ],
        },
      ],
    });
    const text = normalized.content[0] as {
      content: { marks: { attrs: Record<string, unknown> }[] }[];
    };
    expect(text.content[0]?.marks[0]?.attrs).toEqual({
      href: "https://example.com/",
    });
  });

  it("merges adjacent text nodes with identical marks and removes empty ones", () => {
    const normalized = normalizeDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            { type: "text", text: "Hallo " },
            { type: "text", text: "" },
            { type: "text", text: "Welt" },
          ],
        },
      ],
    });
    expect(normalized.content[0]).toEqual({
      type: "paragraph",
      content: [{ type: "text", text: "Hallo Welt" }],
    });
  });

  it("deduplicates and canonically orders marks", () => {
    const normalized = normalizeDraftDocument({
      type: "doc",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: "x",
              marks: [{ type: "italic" }, { type: "bold" }, { type: "italic" }],
            },
          ],
        },
      ],
    });
    const paragraph = normalized.content[0] as {
      content: { marks: { type: string }[] }[];
    };
    expect(paragraph.content[0]?.marks.map((mark) => mark.type)).toEqual([
      "bold",
      "italic",
    ]);
  });

  it("guarantees at least one paragraph", () => {
    expect(normalizeDraftDocument({ type: "doc", content: [] })).toEqual(
      createEmptyDraftDocument(),
    );
  });

  it("throws DraftValidationError for unsupported nodes instead of dropping them", () => {
    expect(() =>
      normalizeDraftDocument({
        type: "doc",
        content: [{ type: "image", attrs: { src: "x" } }],
      }),
    ).toThrow(DraftValidationError);
  });

  it("throws DraftValidationError for unsupported marks instead of dropping them", () => {
    expect(() =>
      normalizeDraftDocument({
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              { type: "text", text: "x", marks: [{ type: "textStyle" }] },
            ],
          },
        ],
      }),
    ).toThrow(DraftValidationError);
  });

  it("throws for invalid roots", () => {
    expect(() => normalizeDraftDocument(null)).toThrow(DraftValidationError);
    expect(() => normalizeDraftDocument({ type: "paragraph" })).toThrow(
      DraftValidationError,
    );
  });

  it("error messages reference structure, not user text", () => {
    try {
      normalizeDraftDocument({
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "GEHEIMER-INHALT",
                marks: [{ type: "nope" }],
              },
            ],
          },
        ],
      });
      expect.unreachable("normalization should have thrown");
    } catch (error) {
      expect(error).toBeInstanceOf(DraftValidationError);
      expect((error as DraftValidationError).message).not.toContain(
        "GEHEIMER-INHALT",
      );
    }
  });
});

describe("round trip", () => {
  it("a normalized document validates unchanged", () => {
    const normalized = normalizeDraftDocument(createSampleDraftDocument());
    const result = validateDraftDocument(normalized);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.document as DraftDocument).toEqual(normalized);
    }
  });
});
