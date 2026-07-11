/**
 * Canonical draft document model.
 *
 * Tiptap/ProseMirror JSON is the only editable source of truth for a draft.
 * This module defines the subset of Tiptap JSON that is allowed in version 1,
 * validates untrusted input against it, and normalizes documents into a
 * single canonical shape.
 *
 * Policy (see docs/adr/0001-canonical-composer.md):
 * - Unsupported node types, mark types, keys, and attributes are REJECTED —
 *   never silently dropped.
 * - Unsafe link hrefs are REMOVED during normalization (the text survives,
 *   the link mark does not) and REJECTED by strict validation.
 * - Normalization is deterministic and idempotent, and never mutates input.
 *
 * This module must stay free of browser globals and framework imports so it
 * can run in the browser, in Node, and in tests unchanged.
 */

import { normalizeHref } from "./links";

export interface BoldMark {
  type: "bold";
}

export interface ItalicMark {
  type: "italic";
}

export interface LinkMark {
  type: "link";
  attrs: {
    href: string;
  };
}

export type DraftMark = BoldMark | ItalicMark | LinkMark;

export interface TextNode {
  type: "text";
  text: string;
  marks?: DraftMark[];
}

export interface HardBreakNode {
  type: "hardBreak";
  marks?: DraftMark[];
}

export type InlineNode = TextNode | HardBreakNode;

export interface ParagraphNode {
  type: "paragraph";
  content?: InlineNode[];
}

export interface BulletListNode {
  type: "bulletList";
  content: ListItemNode[];
}

export interface OrderedListNode {
  type: "orderedList";
  attrs?: {
    start?: number;
    /** Tiptap emits `type: null` for its list-type attribute; normalization removes it. */
    type?: null;
  };
  content: ListItemNode[];
}

export interface ListItemNode {
  type: "listItem";
  content: (ParagraphNode | BulletListNode | OrderedListNode)[];
}

export interface BlockquoteNode {
  type: "blockquote";
  content: BlockNode[];
}

export type BlockNode =
  ParagraphNode | BulletListNode | OrderedListNode | BlockquoteNode;

export interface DraftDocument {
  type: "doc";
  content: BlockNode[];
}

export type ValidationResult =
  { ok: true; document: DraftDocument } | { ok: false; errors: string[] };

export class DraftValidationError extends Error {
  readonly errors: string[];

  constructor(errors: string[]) {
    super(`Invalid draft document: ${errors.join("; ")}`);
    this.name = "DraftValidationError";
    this.errors = errors;
  }
}

const MAX_DEPTH = 20;
const MAX_ERRORS = 20;

const ALLOWED_MARK_TYPES = new Set(["bold", "italic", "link"]);

/** A fresh, canonical empty document (one empty paragraph). */
export function createEmptyDraftDocument(): DraftDocument {
  return { type: "doc", content: [{ type: "paragraph" }] };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  // Accept objects with a null prototype (ProseMirror creates attrs with
  // Object.create(null)) and direct instances of Object — nothing else.
  const proto: unknown = Object.getPrototypeOf(value);
  return proto === null || Object.getPrototypeOf(proto) === null;
}

interface Ctx {
  errors: string[];
}

function report(ctx: Ctx, path: string, message: string): void {
  if (ctx.errors.length < MAX_ERRORS) {
    // Error messages intentionally reference structure only (types, keys,
    // paths) — never user-entered text.
    ctx.errors.push(`${path}: ${message}`);
  }
}

function checkKeys(
  ctx: Ctx,
  path: string,
  value: Record<string, unknown>,
  allowed: readonly string[],
): void {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      report(ctx, path, `unsupported key "${key}"`);
    }
  }
}

function validateMarks(ctx: Ctx, path: string, marks: unknown): void {
  if (!Array.isArray(marks)) {
    report(ctx, path, "marks must be an array");
    return;
  }
  marks.forEach((mark, index) => {
    const markPath = `${path}.marks[${index}]`;
    if (!isPlainObject(mark)) {
      report(ctx, markPath, "mark must be an object");
      return;
    }
    checkKeys(ctx, markPath, mark, ["type", "attrs"]);
    const type = mark.type;
    if (typeof type !== "string" || !ALLOWED_MARK_TYPES.has(type)) {
      report(
        ctx,
        markPath,
        `unsupported mark type ${typeof type === "string" ? `"${type}"` : String(type)}`,
      );
      return;
    }
    if (type === "link") {
      if (!isPlainObject(mark.attrs)) {
        report(ctx, markPath, "link mark requires attrs");
        return;
      }
      checkKeys(ctx, `${markPath}.attrs`, mark.attrs, ["href"]);
      const href = mark.attrs.href;
      if (typeof href !== "string" || normalizeHref(href) === null) {
        report(
          ctx,
          markPath,
          "link href must be a http:, https: or mailto: URL",
        );
      }
    } else if (mark.attrs !== undefined) {
      report(ctx, markPath, `mark "${type}" must not have attrs`);
    }
  });
}

function validateInline(ctx: Ctx, path: string, node: unknown): void {
  if (!isPlainObject(node)) {
    report(ctx, path, "node must be an object");
    return;
  }
  const type = node.type;
  if (type === "text") {
    checkKeys(ctx, path, node, ["type", "text", "marks"]);
    if (typeof node.text !== "string" || node.text.length === 0) {
      report(ctx, path, "text node requires a non-empty string text");
    }
    if (node.marks !== undefined) validateMarks(ctx, path, node.marks);
  } else if (type === "hardBreak") {
    checkKeys(ctx, path, node, ["type", "marks"]);
    if (node.marks !== undefined) validateMarks(ctx, path, node.marks);
  } else {
    report(
      ctx,
      path,
      `unsupported node type ${typeof type === "string" ? `"${type}"` : String(type)}`,
    );
  }
}

function validateParagraph(
  ctx: Ctx,
  path: string,
  node: Record<string, unknown>,
): void {
  checkKeys(ctx, path, node, ["type", "content"]);
  if (node.content !== undefined) {
    if (!Array.isArray(node.content) || node.content.length === 0) {
      report(ctx, path, "paragraph content, when present, must be non-empty");
      return;
    }
    node.content.forEach((child, index) => {
      validateInline(ctx, `${path}.content[${index}]`, child);
    });
  }
}

function validateListItem(
  ctx: Ctx,
  path: string,
  node: unknown,
  depth: number,
): void {
  if (!isPlainObject(node)) {
    report(ctx, path, "node must be an object");
    return;
  }
  if (node.type !== "listItem") {
    report(
      ctx,
      path,
      `expected "listItem", got ${
        typeof node.type === "string" ? `"${node.type}"` : String(node.type)
      }`,
    );
    return;
  }
  checkKeys(ctx, path, node, ["type", "content"]);
  if (!Array.isArray(node.content) || node.content.length === 0) {
    report(ctx, path, "listItem requires non-empty content");
    return;
  }
  node.content.forEach((child, index) => {
    const childPath = `${path}.content[${index}]`;
    if (!isPlainObject(child)) {
      report(ctx, childPath, "node must be an object");
      return;
    }
    if (index === 0 && child.type !== "paragraph") {
      report(ctx, childPath, "listItem must start with a paragraph");
      return;
    }
    if (
      child.type === "paragraph" ||
      child.type === "bulletList" ||
      child.type === "orderedList"
    ) {
      validateBlock(ctx, childPath, child, depth + 1);
    } else {
      report(
        ctx,
        childPath,
        `unsupported node type ${
          typeof child.type === "string"
            ? `"${child.type}"`
            : String(child.type)
        } inside listItem`,
      );
    }
  });
}

function validateBlock(
  ctx: Ctx,
  path: string,
  node: unknown,
  depth: number,
): void {
  if (depth > MAX_DEPTH) {
    report(ctx, path, `nesting deeper than ${MAX_DEPTH} levels`);
    return;
  }
  if (!isPlainObject(node)) {
    report(ctx, path, "node must be an object");
    return;
  }
  const type = node.type;
  switch (type) {
    case "paragraph":
      validateParagraph(ctx, path, node);
      return;
    case "bulletList": {
      checkKeys(ctx, path, node, ["type", "content"]);
      if (!Array.isArray(node.content) || node.content.length === 0) {
        report(ctx, path, "bulletList requires non-empty content");
        return;
      }
      node.content.forEach((child, index) => {
        validateListItem(ctx, `${path}.content[${index}]`, child, depth + 1);
      });
      return;
    }
    case "orderedList": {
      checkKeys(ctx, path, node, ["type", "attrs", "content"]);
      if (node.attrs !== undefined) {
        if (!isPlainObject(node.attrs)) {
          report(ctx, path, "orderedList attrs must be an object");
        } else {
          checkKeys(ctx, `${path}.attrs`, node.attrs, ["start", "type"]);
          const start = node.attrs.start;
          if (
            start !== undefined &&
            (!Number.isInteger(start) || (start as number) < 1)
          ) {
            report(ctx, path, "orderedList start must be a positive integer");
          }
          if (node.attrs.type !== undefined && node.attrs.type !== null) {
            report(ctx, path, "orderedList type attribute must be null");
          }
        }
      }
      if (!Array.isArray(node.content) || node.content.length === 0) {
        report(ctx, path, "orderedList requires non-empty content");
        return;
      }
      node.content.forEach((child, index) => {
        validateListItem(ctx, `${path}.content[${index}]`, child, depth + 1);
      });
      return;
    }
    case "blockquote": {
      checkKeys(ctx, path, node, ["type", "content"]);
      if (!Array.isArray(node.content) || node.content.length === 0) {
        report(ctx, path, "blockquote requires non-empty content");
        return;
      }
      node.content.forEach((child, index) => {
        validateBlock(ctx, `${path}.content[${index}]`, child, depth + 1);
      });
      return;
    }
    default:
      report(
        ctx,
        path,
        `unsupported node type ${typeof type === "string" ? `"${type}"` : String(type)}`,
      );
  }
}

/**
 * Strict validation of untrusted input against the canonical schema.
 * Rejects unsupported nodes, marks, keys, attributes, and unsafe links.
 */
export function validateDraftDocument(input: unknown): ValidationResult {
  const ctx: Ctx = { errors: [] };
  if (!isPlainObject(input)) {
    return { ok: false, errors: ["doc: document must be an object"] };
  }
  if (input.type !== "doc") {
    return { ok: false, errors: ['doc: root node type must be "doc"'] };
  }
  checkKeys(ctx, "doc", input, ["type", "content"]);
  if (!Array.isArray(input.content) || input.content.length === 0) {
    report(ctx, "doc", "document requires non-empty content");
  } else {
    input.content.forEach((child, index) => {
      validateBlock(ctx, `doc.content[${index}]`, child, 1);
    });
  }
  if (ctx.errors.length > 0) {
    return { ok: false, errors: ctx.errors };
  }
  return { ok: true, document: input as unknown as DraftDocument };
}

function markSignature(mark: DraftMark): string {
  return mark.type === "link" ? `link:${mark.attrs.href}` : mark.type;
}

const MARK_ORDER: Record<DraftMark["type"], number> = {
  bold: 0,
  italic: 1,
  link: 2,
};

/**
 * Rebuilds marks in canonical form: unknown-safe href normalization has
 * already happened; here we deduplicate by type and sort deterministically.
 * Returns undefined when no marks survive.
 */
function normalizeMarks(marks: unknown): DraftMark[] | undefined {
  if (!Array.isArray(marks)) return undefined;
  const seen = new Set<string>();
  const result: DraftMark[] = [];
  for (const mark of marks) {
    if (!isPlainObject(mark) || typeof mark.type !== "string") continue;
    if (mark.type === "bold" || mark.type === "italic") {
      if (!seen.has(mark.type)) {
        seen.add(mark.type);
        result.push({ type: mark.type });
      }
    } else if (mark.type === "link") {
      const attrs = isPlainObject(mark.attrs) ? mark.attrs : {};
      const href = normalizeHref(attrs.href);
      // Unsafe or missing hrefs: the link mark is removed, text survives.
      if (href !== null && !seen.has("link")) {
        seen.add("link");
        result.push({ type: "link", attrs: { href } });
      }
    }
    // Unsupported mark types are left in place here and rejected by the
    // strict validation that runs after normalization.
    else if (mark.type !== "link") {
      return UNSUPPORTED_MARKS;
    }
  }
  result.sort((a, b) => MARK_ORDER[a.type] - MARK_ORDER[b.type]);
  return result.length > 0 ? result : undefined;
}

/** Sentinel: propagated so strict validation reports the unsupported mark. */
const UNSUPPORTED_MARKS: DraftMark[] = [
  { type: "__unsupported__" } as unknown as DraftMark,
];

function normalizeInline(nodes: unknown): InlineNode[] {
  if (!Array.isArray(nodes)) return [];
  const result: InlineNode[] = [];
  for (const node of nodes) {
    if (!isPlainObject(node)) {
      result.push(node as unknown as InlineNode); // rejected by validation
      continue;
    }
    if (node.type === "text") {
      if (typeof node.text !== "string" || node.text.length === 0) continue;
      const marks = normalizeMarks(node.marks);
      const previous = result[result.length - 1];
      if (
        previous !== undefined &&
        isTextNode(previous) &&
        signatureOf(previous.marks) === signatureOf(marks)
      ) {
        previous.text += node.text;
      } else {
        result.push(
          marks
            ? { type: "text", text: node.text, marks }
            : { type: "text", text: node.text },
        );
      }
    } else if (node.type === "hardBreak") {
      const marks = normalizeMarks(node.marks);
      result.push(marks ? { type: "hardBreak", marks } : { type: "hardBreak" });
    } else {
      result.push(node as unknown as InlineNode); // rejected by validation
    }
  }
  return result;
}

function isTextNode(node: InlineNode): node is TextNode {
  return node.type === "text";
}

function signatureOf(marks: DraftMark[] | undefined): string {
  return (marks ?? []).map(markSignature).join("|");
}

function normalizeBlock(node: unknown): unknown {
  if (!isPlainObject(node)) return node;
  switch (node.type) {
    case "paragraph": {
      const content = normalizeInline(node.content);
      return content.length > 0
        ? { type: "paragraph", content }
        : { type: "paragraph" };
    }
    case "bulletList":
    case "orderedList": {
      const normalized: Record<string, unknown> = { type: node.type };
      if (node.type === "orderedList" && isPlainObject(node.attrs)) {
        const start = node.attrs.start;
        if (Number.isInteger(start) && (start as number) > 1) {
          normalized.attrs = { start };
        }
        // `type: null` and `start: 1` are Tiptap defaults — dropped.
      }
      normalized.content = Array.isArray(node.content)
        ? node.content.map((item) => normalizeListItem(item))
        : node.content;
      return normalized;
    }
    case "blockquote": {
      return {
        type: "blockquote",
        content: Array.isArray(node.content)
          ? node.content.map((child) => normalizeBlock(child))
          : node.content,
      };
    }
    default:
      return node; // rejected by validation
  }
}

function normalizeListItem(node: unknown): unknown {
  if (!isPlainObject(node) || node.type !== "listItem") return node;
  return {
    type: "listItem",
    content: Array.isArray(node.content)
      ? node.content.map((child) => normalizeBlock(child))
      : node.content,
  };
}

/**
 * Normalizes untrusted input into canonical form, then validates strictly.
 *
 * Normalization (deterministic, idempotent, non-mutating):
 * - removes empty text nodes and merges adjacent text nodes with equal marks;
 * - deduplicates marks and sorts them into a canonical order;
 * - removes link marks whose href is not http:, https: or mailto: (the text
 *   survives, the link does not) and normalizes surviving hrefs;
 * - drops presentational/default attributes (link target/rel/class,
 *   orderedList `type: null` and `start: 1`);
 * - guarantees the document has at least one paragraph.
 *
 * Unsupported nodes and marks are NOT dropped: they fail the strict
 * validation that runs afterwards, and a DraftValidationError is thrown.
 */
export function normalizeDraftDocument(input: unknown): DraftDocument {
  if (!isPlainObject(input) || input.type !== "doc") {
    // A non-doc root can never validate, so validation always rejects it.
    throw new DraftValidationError(
      isPlainObject(input)
        ? ['doc: root node type must be "doc"']
        : ["doc: document must be an object"],
    );
  }
  const blocks = Array.isArray(input.content)
    ? input.content.map((child) => normalizeBlock(child))
    : [];
  const normalized = {
    type: "doc",
    content: blocks.length > 0 ? blocks : [{ type: "paragraph" }],
  };
  const result = validateDraftDocument(normalized);
  if (!result.ok) {
    throw new DraftValidationError(result.errors);
  }
  return result.document;
}
