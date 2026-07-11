// @vitest-environment node

import { describe, expect, it } from "vitest";
import { renderDraft } from "@/server/render/renderDraft";
import type { DraftDocument, ParagraphNode } from "@/lib/composer/canonical";
import { createSampleDraftDocument } from "@/lib/composer/samples";
import { deepFreeze } from "./helpers";

function doc(content: DraftDocument["content"]): DraftDocument {
  return { type: "doc", content };
}

function paragraph(text: string): ParagraphNode {
  return { type: "paragraph", content: [{ type: "text", text }] };
}

describe("renderDraft", () => {
  it("renders a paragraph into e-mail HTML with a doctype and charset", async () => {
    const { html } = await renderDraft(doc([paragraph("Hallo Welt")]));
    expect(html.toLowerCase()).toMatch(/^<!doctype/);
    expect(html).toContain("Hallo Welt");
    expect(html.toLowerCase()).toContain("charset");
  });

  it("renders bold and italic marks", async () => {
    const { html } = await renderDraft(
      doc([
        {
          type: "paragraph",
          content: [
            { type: "text", text: "fett", marks: [{ type: "bold" }] },
            { type: "text", text: " und " },
            { type: "text", text: "kursiv", marks: [{ type: "italic" }] },
          ],
        },
      ]),
    );
    expect(html).toContain("<strong>fett</strong>");
    expect(html).toContain("<em>kursiv</em>");
  });

  it("renders bullet and ordered lists", async () => {
    const { html } = await renderDraft(
      doc([
        {
          type: "bulletList",
          content: [
            { type: "listItem", content: [paragraph("Äpfel")] },
            { type: "listItem", content: [paragraph("Birnen")] },
          ],
        },
        {
          type: "orderedList",
          attrs: { start: 2 },
          content: [{ type: "listItem", content: [paragraph("zwei")] }],
        },
      ]),
    );
    expect(html).toContain("<ul");
    expect(html).toContain("<ol");
    expect(html).toContain('start="2"');
    expect(html).toContain("Äpfel");
  });

  it("renders blockquotes", async () => {
    const { html } = await renderDraft(
      doc([{ type: "blockquote", content: [paragraph("Zitat")] }]),
    );
    expect(html).toContain("<blockquote");
    expect(html).toContain("Zitat");
  });

  it("renders safe links with their href", async () => {
    const { html } = await renderDraft(
      doc([
        {
          type: "paragraph",
          content: [
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
    );
    expect(html).toContain('href="https://example.com/"');
    expect(html).toContain("Beispiel");
  });

  it("renders hard breaks", async () => {
    const { html } = await renderDraft(
      doc([
        {
          type: "paragraph",
          content: [
            { type: "text", text: "eins" },
            { type: "hardBreak" },
            { type: "text", text: "zwei" },
          ],
        },
      ]),
    );
    expect(html).toMatch(/<br\s*\/?>/);
  });

  it("preserves German umlauts and ß", async () => {
    const { html, text } = await renderDraft(
      doc([paragraph("Überprüfung der Größe, Straße und Grüße.")]),
    );
    expect(html).toContain("Überprüfung der Größe, Straße und Grüße.");
    expect(text).toContain("Überprüfung der Größe, Straße und Grüße.");
  });

  it("preserves Arabic text", async () => {
    const { html, text } = await renderDraft(
      doc([paragraph("مرحباً، هذه رسالة تجريبية.")]),
    );
    expect(html).toContain("مرحباً، هذه رسالة تجريبية.");
    expect(text).toContain("مرحباً، هذه رسالة تجريبية.");
  });

  it("keeps mixed Arabic and German content with per-paragraph auto direction and LTR document root", async () => {
    const { html } = await renderDraft(
      doc([paragraph("Vielen Dank — شكراً جزيلاً — für Ihre Rückmeldung.")]),
    );
    expect(html).toContain(
      "Vielen Dank — شكراً جزيلاً — für Ihre Rückmeldung.",
    );
    expect(html).toContain('dir="auto"');
    expect(html).toMatch(/<html[^>]*dir="ltr"/);
  });

  it("produces deterministic HTML and text output", async () => {
    const input = createSampleDraftDocument();
    const first = await renderDraft(input);
    const second = await renderDraft(createSampleDraftDocument());
    expect(first.html).toBe(second.html);
    expect(first.text).toBe(second.text);
  });

  it("does not mutate the input document", async () => {
    const input = deepFreeze(createSampleDraftDocument());
    await expect(renderDraft(input)).resolves.toBeDefined();
    expect(input).toEqual(createSampleDraftDocument());
  });

  it("rejects invalid canonical documents", async () => {
    await expect(
      renderDraft({ type: "doc", content: [{ type: "image" }] }),
    ).rejects.toThrow(/Invalid draft document/);
    await expect(renderDraft(null)).rejects.toThrow(/Invalid draft document/);
  });

  it("produces a meaningful plain-text alternative", async () => {
    const { text } = await renderDraft(createSampleDraftDocument());
    expect(text).toContain("Sehr geehrte Damen und Herren,");
    expect(text).toContain("- ");
    expect(text).toContain("1. ");
    expect(text).toContain("> ");
    expect(text).toContain("(https://example.com/)");
  });
});
