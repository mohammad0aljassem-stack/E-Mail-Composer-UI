/**
 * Deterministic plain-text rendering of a canonical draft document.
 *
 * The plain-text body is a derived output (like HTML) — it is never stored
 * as a source document. This module is pure and free of browser globals.
 */

import type {
  BlockNode,
  DraftDocument,
  DraftMark,
  InlineNode,
  ListItemNode,
} from "./canonical";

function linkHrefOf(marks: DraftMark[] | undefined): string | null {
  const link = (marks ?? []).find((mark) => mark.type === "link");
  return link && link.type === "link" ? link.attrs.href : null;
}

/**
 * Renders inline content. Consecutive text nodes that belong to the same
 * link are grouped so the URL is appended once: "label (https://…)". When
 * the label already equals the URL, it is not repeated.
 */
function renderInline(nodes: InlineNode[] | undefined): string {
  if (!nodes || nodes.length === 0) {
    return "";
  }
  let out = "";
  let index = 0;
  while (index < nodes.length) {
    const node = nodes[index];
    if (node === undefined) {
      break;
    }
    if (node.type === "hardBreak") {
      out += "\n";
      index += 1;
      continue;
    }
    const href = linkHrefOf(node.marks);
    if (href === null) {
      out += node.text;
      index += 1;
      continue;
    }
    let label = "";
    while (index < nodes.length) {
      const current = nodes[index];
      if (
        current === undefined ||
        current.type !== "text" ||
        linkHrefOf(current.marks) !== href
      ) {
        break;
      }
      label += current.text;
      index += 1;
    }
    out += label === href ? label : `${label} (${href})`;
  }
  return out;
}

function prefixLines(text: string, first: string, rest: string): string {
  return text
    .split("\n")
    .map((line, index) => {
      const prefix = index === 0 ? first : rest;
      return line.length > 0 ? prefix + line : prefix.trimEnd();
    })
    .join("\n");
}

function renderListItems(
  items: ListItemNode[],
  marker: (index: number) => string,
): string {
  return items
    .map((item, index) => {
      const body = item.content.map((child) => renderBlock(child)).join("\n");
      const itemMarker = marker(index);
      return prefixLines(body, itemMarker, " ".repeat(itemMarker.length));
    })
    .join("\n");
}

function renderBlock(block: BlockNode): string {
  switch (block.type) {
    case "paragraph":
      return renderInline(block.content);
    case "bulletList":
      return renderListItems(block.content, () => "- ");
    case "orderedList": {
      const start = block.attrs?.start ?? 1;
      return renderListItems(block.content, (index) => `${start + index}. `);
    }
    case "blockquote": {
      const inner = block.content
        .map((child) => renderBlock(child))
        .join("\n\n");
      return prefixLines(inner, "> ", "> ");
    }
  }
}

/** Renders the document to plain text. Deterministic; never mutates input. */
export function renderPlainText(document: DraftDocument): string {
  return document.content.map((block) => renderBlock(block)).join("\n\n");
}
