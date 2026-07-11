/**
 * Minimal paragraph-text signature body builder.
 *
 * The signature manager UI edits signature bodies as plain multi-line text.
 * Each line becomes one canonical paragraph (blank lines become empty
 * paragraphs); the text is stored verbatim as text node content and is
 * never interpreted as HTML or markup. Round-trips deterministically for
 * documents this builder produced.
 */

import {
  normalizeDraftDocument,
  type DraftDocument,
  type ParagraphNode,
} from "@/lib/composer/canonical";

/** Converts plain multi-line text into a canonical paragraph-only document. */
export function signatureDocumentFromText(text: string): DraftDocument {
  const lines = text.split(/\r\n|\r|\n/);
  const content: ParagraphNode[] = lines.map((line) =>
    line.length > 0
      ? { type: "paragraph", content: [{ type: "text", text: line }] }
      : { type: "paragraph" },
  );
  return normalizeDraftDocument({ type: "doc", content });
}

/**
 * Converts a canonical document back to editable plain text: one line per
 * paragraph, hard breaks as newlines. Only paragraph blocks are supported
 * (this is the inverse of `signatureDocumentFromText`); other block types
 * are rendered by their nested paragraph text lines.
 */
export function signatureTextFromDocument(document: DraftDocument): string {
  const lines: string[] = [];
  const walk = (blocks: readonly unknown[]): void => {
    for (const block of blocks) {
      if (typeof block !== "object" || block === null) continue;
      const node = block as {
        type?: string;
        content?: unknown[];
      };
      if (node.type === "paragraph") {
        let line = "";
        for (const inline of node.content ?? []) {
          const child = inline as { type?: string; text?: string };
          if (child.type === "text" && typeof child.text === "string") {
            line += child.text;
          } else if (child.type === "hardBreak") {
            lines.push(line);
            line = "";
          }
        }
        lines.push(line);
      } else if (Array.isArray(node.content)) {
        walk(node.content);
      }
    }
  };
  walk(document.content);
  return lines.join("\n");
}
