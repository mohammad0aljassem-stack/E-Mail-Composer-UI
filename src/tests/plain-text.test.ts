// @vitest-environment node

import { describe, expect, it } from "vitest";
import { renderPlainText } from "@/lib/composer/plain-text";
import type { DraftDocument, ParagraphNode } from "@/lib/composer/canonical";
import { createSampleDraftDocument } from "@/lib/composer/samples";
import { deepFreeze } from "./helpers";

function doc(content: DraftDocument["content"]): DraftDocument {
  return { type: "doc", content };
}

function paragraph(text: string): ParagraphNode {
  return { type: "paragraph", content: [{ type: "text", text }] };
}

describe("renderPlainText", () => {
  it("joins paragraphs with a blank line", () => {
    expect(renderPlainText(doc([paragraph("Eins"), paragraph("Zwei")]))).toBe(
      "Eins\n\nZwei",
    );
  });

  it("renders empty paragraphs as blank lines", () => {
    expect(
      renderPlainText(
        doc([paragraph("Eins"), { type: "paragraph" }, paragraph("Drei")]),
      ),
    ).toBe("Eins\n\n\n\nDrei");
  });

  it("renders hard breaks as single newlines", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "paragraph",
            content: [
              { type: "text", text: "Zeile 1" },
              { type: "hardBreak" },
              { type: "text", text: "Zeile 2" },
            ],
          },
        ]),
      ),
    ).toBe("Zeile 1\nZeile 2");
  });

  it("renders bullet lists", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "bulletList",
            content: [
              { type: "listItem", content: [paragraph("Äpfel")] },
              { type: "listItem", content: [paragraph("Birnen")] },
            ],
          },
        ]),
      ),
    ).toBe("- Äpfel\n- Birnen");
  });

  it("renders ordered lists respecting the start attribute", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "orderedList",
            attrs: { start: 3 },
            content: [
              { type: "listItem", content: [paragraph("drei")] },
              { type: "listItem", content: [paragraph("vier")] },
            ],
          },
        ]),
      ),
    ).toBe("3. drei\n4. vier");
  });

  it("indents nested lists under their item", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "bulletList",
            content: [
              {
                type: "listItem",
                content: [
                  paragraph("Oben"),
                  {
                    type: "bulletList",
                    content: [
                      { type: "listItem", content: [paragraph("Unten")] },
                    ],
                  },
                ],
              },
            ],
          },
        ]),
      ),
    ).toBe("- Oben\n  - Unten");
  });

  it("prefixes blockquotes with '> '", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "blockquote",
            content: [paragraph("Erste"), paragraph("Zweite")],
          },
        ]),
      ),
    ).toBe("> Erste\n>\n> Zweite");
  });

  it("appends link targets after the label", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "paragraph",
            content: [
              { type: "text", text: "Siehe " },
              {
                type: "text",
                text: "Beispiel",
                marks: [
                  { type: "link", attrs: { href: "https://example.com/" } },
                ],
              },
            ],
          },
        ]),
      ),
    ).toBe("Siehe Beispiel (https://example.com/)");
  });

  it("does not repeat the URL when the label equals the URL", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "https://example.com/",
                marks: [
                  { type: "link", attrs: { href: "https://example.com/" } },
                ],
              },
            ],
          },
        ]),
      ),
    ).toBe("https://example.com/");
  });

  it("appends one URL for a link spanning differently marked text runs", () => {
    expect(
      renderPlainText(
        doc([
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "Beispiel ",
                marks: [
                  { type: "link", attrs: { href: "https://example.com/" } },
                ],
              },
              {
                type: "text",
                text: "Seite",
                marks: [
                  { type: "bold" },
                  { type: "link", attrs: { href: "https://example.com/" } },
                ],
              },
            ],
          },
        ]),
      ),
    ).toBe("Beispiel Seite (https://example.com/)");
  });

  it("preserves German umlauts, ß and Arabic characters", () => {
    const text = renderPlainText(
      doc([
        paragraph("Überprüfung der Größe, Straße und Grüße."),
        paragraph("مرحباً بالعالم"),
      ]),
    );
    expect(text).toBe(
      "Überprüfung der Größe, Straße und Grüße.\n\nمرحباً بالعالم",
    );
  });

  it("is deterministic and does not mutate its input", () => {
    const input = deepFreeze(createSampleDraftDocument());
    const first = renderPlainText(input);
    const second = renderPlainText(input);
    expect(first).toBe(second);
    expect(input).toEqual(createSampleDraftDocument());
  });
});
