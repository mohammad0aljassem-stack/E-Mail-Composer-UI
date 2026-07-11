/**
 * Deterministic template resolution.
 *
 * Applying a template version to a set of variable values produces a plain
 * Phase 1 canonical draft document and a rendered subject string. Saved
 * drafts NEVER contain variable nodes.
 *
 * Guarantees:
 * - Missing required values block the whole application — no defaults are
 *   ever invented and no partial application happens.
 * - Values are inserted verbatim as ordinary text node content. They are
 *   never parsed, never re-templated, and never turned into HTML strings —
 *   a value of "<script>" or "{{other}}" stays inert literal text.
 * - Same inputs produce byte-identical JSON output.
 */

import {
  normalizeDraftDocument,
  validateDraftDocument,
  type BlockNode,
  type DraftDocument,
  type InlineNode,
  type ListItemNode,
  type ParagraphNode,
} from "@/lib/composer/canonical";
import type { TemplateVersionRecord } from "@/lib/phase2/contracts";
import { renderSubject } from "./subject-template";
import {
  resolveTemplateVariables,
  validateTemplateDocument,
  type TemplateBlockNode,
  type TemplateInlineNode,
  type TemplateListItemNode,
  type TemplateParagraphNode,
} from "./template-document";

export interface ApplyTemplateFailure {
  ok: false;
  reason: "invalid_template" | "missing_variables";
  /** Structural validation messages; empty for pure missing-variable failures. */
  errors: string[];
  /** Keys still needing values; empty for invalid-template failures. */
  missingVariables: string[];
}

export type ApplyTemplateResult =
  { ok: true; document: DraftDocument; subject: string } | ApplyTemplateFailure;

function invalidTemplate(errors: string[]): ApplyTemplateFailure {
  return {
    ok: false,
    reason: "invalid_template",
    errors,
    missingVariables: [],
  };
}

function valueOf(
  values: Record<string, string>,
  key: string,
): string | undefined {
  return Object.hasOwn(values, key) ? values[key] : undefined;
}

function resolveInline(
  nodes: readonly TemplateInlineNode[],
  values: Record<string, string>,
): InlineNode[] {
  const result: InlineNode[] = [];
  for (const node of nodes) {
    if (node.type !== "variable") {
      result.push(node);
      continue;
    }
    const value = valueOf(values, node.attrs.key);
    // An absent or empty optional value removes the variable node cleanly.
    // (Required variables were checked before substitution started.)
    if (value !== undefined && value.length > 0) {
      result.push({ type: "text", text: value });
    }
  }
  return result;
}

function resolveParagraph(
  node: TemplateParagraphNode,
  values: Record<string, string>,
): ParagraphNode {
  if (node.content === undefined) {
    return { type: "paragraph" };
  }
  const content = resolveInline(node.content, values);
  // If removals empty the paragraph it stays valid: no content key at all.
  return content.length > 0
    ? { type: "paragraph", content }
    : { type: "paragraph" };
}

function resolveListItem(
  node: TemplateListItemNode,
  values: Record<string, string>,
): ListItemNode {
  return {
    type: "listItem",
    content: node.content.map((child) => {
      switch (child.type) {
        case "paragraph":
          return resolveParagraph(child, values);
        case "bulletList":
          return resolveBulletList(child, values);
        case "orderedList":
          return resolveOrderedList(child, values);
      }
    }),
  };
}

function resolveBulletList(
  node: Extract<TemplateBlockNode, { type: "bulletList" }>,
  values: Record<string, string>,
): Extract<BlockNode, { type: "bulletList" }> {
  return {
    type: "bulletList",
    content: node.content.map((item) => resolveListItem(item, values)),
  };
}

function resolveOrderedList(
  node: Extract<TemplateBlockNode, { type: "orderedList" }>,
  values: Record<string, string>,
): Extract<BlockNode, { type: "orderedList" }> {
  const resolved: Extract<BlockNode, { type: "orderedList" }> = {
    type: "orderedList",
    content: node.content.map((item) => resolveListItem(item, values)),
  };
  if (node.attrs !== undefined) {
    resolved.attrs = { ...node.attrs };
  }
  return resolved;
}

function resolveBlock(
  node: TemplateBlockNode,
  values: Record<string, string>,
): BlockNode {
  switch (node.type) {
    case "paragraph":
      return resolveParagraph(node, values);
    case "bulletList":
      return resolveBulletList(node, values);
    case "orderedList":
      return resolveOrderedList(node, values);
    case "blockquote":
      return {
        type: "blockquote",
        content: node.content.map((child) => resolveBlock(child, values)),
      };
  }
}

function isMissing(value: string | undefined): boolean {
  return value === undefined || value.trim().length === 0;
}

/**
 * Applies a template version with the given variable values.
 *
 * - Validates the body via `validateTemplateDocument` and the subject via
 *   the strict `{{key}}` scanner.
 * - Required variables are the union of the declared `variable_schema` and
 *   the variables collected from subject + body nodes.
 * - Missing required values (absent, empty, or whitespace-only) fail the
 *   whole call with a structured `missingVariables` list.
 * - On success, the returned document has been normalized and passes the
 *   Phase 1 `validateDraftDocument` — it contains no variable nodes.
 */
export function applyTemplate({
  version,
  values,
}: {
  version: TemplateVersionRecord;
  values: Record<string, string>;
}): ApplyTemplateResult {
  const body = validateTemplateDocument(version.body_template_json);
  if (!body.ok) {
    return invalidTemplate(body.errors);
  }
  const resolvedVariables = resolveTemplateVariables(version);
  if (!resolvedVariables.ok) {
    return invalidTemplate(resolvedVariables.errors);
  }
  const variables = resolvedVariables.variables;

  const missingVariables = variables
    .filter((spec) => spec.required && isMissing(valueOf(values, spec.key)))
    .map((spec) => spec.key);
  if (missingVariables.length > 0) {
    return {
      ok: false,
      reason: "missing_variables",
      errors: [],
      missingVariables,
    };
  }

  // Subject rendering: optional variables without a value render as "".
  const subjectValues: Record<string, string> = {};
  for (const spec of variables) {
    subjectValues[spec.key] = valueOf(values, spec.key) ?? "";
  }
  const subject = renderSubject(version.subject_template, subjectValues);
  if (!subject.ok) {
    return invalidTemplate(subject.errors);
  }

  const substituted = {
    type: "doc" as const,
    content: body.document.content.map((block) => resolveBlock(block, values)),
  };
  const document = normalizeDraftDocument(substituted);
  const check = validateDraftDocument(document);
  if (!check.ok) {
    // Unreachable by construction; kept as a hard guarantee.
    return invalidTemplate(check.errors);
  }
  return { ok: true, document: check.document, subject: subject.subject };
}
