/**
 * Template document model.
 *
 * A template body is a Phase 1 canonical draft document PLUS exactly one
 * extra inline node type:
 *
 *   { "type": "variable", "attrs": { "key": string, "label": string, "required": boolean } }
 *
 * Validation strategy: variable nodes found in inline positions are checked
 * strictly here, then replaced by a placeholder text node, and the resulting
 * document is run through the Phase 1 validator. Anything the Phase 1
 * validator would reject stays rejected — including variable nodes that
 * appear in block positions, which are never substituted and therefore fail
 * as an unsupported node type.
 *
 * This module is pure: no browser globals, no dynamic code, no HTML strings.
 */

import {
  validateDraftDocument,
  type HardBreakNode,
  type TextNode,
} from "@/lib/composer/canonical";
import {
  TEMPLATE_VARIABLE_KEY_PATTERN,
  type TemplateVariableSpec,
} from "@/lib/phase2/contracts";
import { parseSubjectTemplate } from "./subject-template";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface TemplateVariableNode {
  type: "variable";
  attrs: TemplateVariableSpec;
}

export type TemplateInlineNode =
  TextNode | HardBreakNode | TemplateVariableNode;

export interface TemplateParagraphNode {
  type: "paragraph";
  content?: TemplateInlineNode[];
}

export interface TemplateBulletListNode {
  type: "bulletList";
  content: TemplateListItemNode[];
}

export interface TemplateOrderedListNode {
  type: "orderedList";
  attrs?: { start?: number; type?: null };
  content: TemplateListItemNode[];
}

export interface TemplateListItemNode {
  type: "listItem";
  content: (
    TemplateParagraphNode | TemplateBulletListNode | TemplateOrderedListNode
  )[];
}

export interface TemplateBlockquoteNode {
  type: "blockquote";
  content: TemplateBlockNode[];
}

export type TemplateBlockNode =
  | TemplateParagraphNode
  | TemplateBulletListNode
  | TemplateOrderedListNode
  | TemplateBlockquoteNode;

export interface TemplateDocument {
  type: "doc";
  content: TemplateBlockNode[];
}

export type TemplateValidationResult =
  { ok: true; document: TemplateDocument } | { ok: false; errors: string[] };

export type VariablesResult =
  | { ok: true; variables: TemplateVariableSpec[] }
  | { ok: false; errors: string[] };

export const TEMPLATE_VARIABLE_LABEL_MAX_LENGTH = 200;

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const MAX_WALK_DEPTH = 25;
const MAX_ERRORS = 20;

interface Ctx {
  errors: string[];
}

function report(ctx: Ctx, path: string, message: string): void {
  if (ctx.errors.length < MAX_ERRORS) {
    ctx.errors.push(`${path}: ${message}`);
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const proto: unknown = Object.getPrototypeOf(value);
  return proto === null || Object.getPrototypeOf(proto) === null;
}

/**
 * Validates one variable node in an inline position. Reports errors into
 * `ctx`; error messages reference structure only, never user text.
 */
function validateVariableNode(
  ctx: Ctx,
  path: string,
  node: Record<string, unknown>,
): void {
  for (const key of Object.keys(node)) {
    if (key === "marks") {
      report(ctx, path, "variable node must not have marks");
    } else if (key !== "type" && key !== "attrs") {
      report(ctx, path, `unsupported key "${key}"`);
    }
  }
  const attrs = node.attrs;
  if (!isPlainObject(attrs)) {
    report(ctx, path, "variable node requires attrs");
    return;
  }
  for (const key of Object.keys(attrs)) {
    if (key !== "key" && key !== "label" && key !== "required") {
      report(ctx, `${path}.attrs`, `unsupported key "${key}"`);
    }
  }
  const varKey = attrs.key;
  if (
    typeof varKey !== "string" ||
    !TEMPLATE_VARIABLE_KEY_PATTERN.test(varKey)
  ) {
    report(
      ctx,
      `${path}.attrs`,
      "variable key must match /^[a-z][a-z0-9_]{0,63}$/",
    );
  }
  const label = attrs.label;
  if (
    typeof label !== "string" ||
    label.trim().length === 0 ||
    label.length > TEMPLATE_VARIABLE_LABEL_MAX_LENGTH
  ) {
    report(
      ctx,
      `${path}.attrs`,
      `variable label must be a non-empty string of at most ${TEMPLATE_VARIABLE_LABEL_MAX_LENGTH} characters`,
    );
  }
  if (typeof attrs.required !== "boolean") {
    report(ctx, `${path}.attrs`, "variable required flag must be a boolean");
  }
}

/**
 * Recursively rebuilds the tree, replacing valid-position variable nodes
 * with placeholder text nodes so the Phase 1 validator can check the rest.
 * Variable nodes outside paragraph content are left in place and rejected
 * by the Phase 1 validator as unsupported node types.
 */
function substituteVariables(
  ctx: Ctx,
  path: string,
  node: unknown,
  inline: boolean,
  depth: number,
): unknown {
  if (depth > MAX_WALK_DEPTH || !isPlainObject(node)) {
    return node;
  }
  if (node.type === "variable") {
    if (!inline) {
      return node; // Phase 1 reports: unsupported node type "variable".
    }
    validateVariableNode(ctx, path, node);
    return { type: "text", text: "x" };
  }
  if (!Array.isArray(node.content)) {
    return node;
  }
  const childInline = node.type === "paragraph";
  return {
    ...node,
    content: node.content.map((child, index) =>
      substituteVariables(
        ctx,
        `${path}.content[${index}]`,
        child,
        childInline,
        depth + 1,
      ),
    ),
  };
}

/**
 * Strict validation of an untrusted template body. Accepts exactly the
 * Phase 1 canonical schema plus the `variable` inline node; rejects variable
 * nodes with bad keys, bad labels, marks, unknown attrs, or in block
 * positions. Never mutates input.
 */
export function validateTemplateDocument(
  input: unknown,
): TemplateValidationResult {
  if (!isPlainObject(input)) {
    return { ok: false, errors: ["doc: document must be an object"] };
  }
  if (input.type !== "doc") {
    return { ok: false, errors: ['doc: root node type must be "doc"'] };
  }
  const ctx: Ctx = { errors: [] };
  const substituted = substituteVariables(ctx, "doc", input, false, 0);
  const phase1 = validateDraftDocument(substituted);
  const errors = phase1.ok ? ctx.errors : [...ctx.errors, ...phase1.errors];
  if (errors.length > 0) {
    return { ok: false, errors };
  }
  return { ok: true, document: input as unknown as TemplateDocument };
}

// ---------------------------------------------------------------------------
// Variable collection
// ---------------------------------------------------------------------------

/** One variable occurrence, in document order. Subject occurrences have no label. */
export interface VariableOccurrence {
  key: string;
  /** null for subject placeholders, which carry no label of their own. */
  label: string | null;
  required: boolean;
}

function collectBodyOccurrences(
  blocks: readonly unknown[],
  out: VariableOccurrence[],
): void {
  for (const block of blocks) {
    if (!isPlainObject(block)) continue;
    if (block.type === "variable" && isPlainObject(block.attrs)) {
      out.push({
        key: String(block.attrs.key),
        label: String(block.attrs.label),
        required: block.attrs.required === true,
      });
    } else if (Array.isArray(block.content)) {
      collectBodyOccurrences(block.content, out);
    }
  }
}

function mergeOccurrences(
  occurrences: readonly VariableOccurrence[],
): VariablesResult {
  const order: string[] = [];
  const byKey = new Map<string, { label: string | null; required: boolean }>();
  const errors: string[] = [];
  for (const occurrence of occurrences) {
    const existing = byKey.get(occurrence.key);
    if (existing === undefined) {
      order.push(occurrence.key);
      byKey.set(occurrence.key, {
        label: occurrence.label,
        required: occurrence.required,
      });
      continue;
    }
    if (
      existing.label !== null &&
      occurrence.label !== null &&
      existing.label !== occurrence.label
    ) {
      errors.push(`conflicting labels for variable "${occurrence.key}"`);
    }
    if (existing.label === null) {
      existing.label = occurrence.label;
    }
    existing.required = existing.required || occurrence.required;
  }
  if (errors.length > 0) {
    return { ok: false, errors };
  }
  return {
    ok: true,
    variables: order.map((key) => {
      const entry = byKey.get(key) as {
        label: string | null;
        required: boolean;
      };
      return { key, label: entry.label ?? key, required: entry.required };
    }),
  };
}

/**
 * Collects the variables used by a template, in document order: subject
 * placeholders first (when a subject template is provided), then body
 * variable nodes. Deduplicated by key; conflicting labels are an error.
 * Subject placeholders carry no label of their own (the key doubles as the
 * label unless a body node or the declared schema provides one) and are
 * always required.
 */
export function collectVariables(
  document: TemplateDocument,
  subjectTemplate?: string,
): VariablesResult {
  const occurrences: VariableOccurrence[] = [];
  if (subjectTemplate !== undefined) {
    const parsed = parseSubjectTemplate(subjectTemplate);
    if (!parsed.ok) {
      return { ok: false, errors: parsed.errors };
    }
    for (const token of parsed.tokens) {
      if (token.kind === "variable") {
        occurrences.push({ key: token.key, label: null, required: true });
      }
    }
  }
  collectBodyOccurrences(document.content, occurrences);
  return mergeOccurrences(occurrences);
}

/**
 * Validates the shape of a declared `variable_schema`: an array of
 * `{ key, label, required }` entries with strict key format, bounded
 * non-empty labels, boolean required flags, and no duplicate keys.
 */
export function declaredVariables(schema: unknown): VariablesResult {
  if (!Array.isArray(schema)) {
    return { ok: false, errors: ["variable_schema must be an array"] };
  }
  const errors: string[] = [];
  const seen = new Set<string>();
  const variables: TemplateVariableSpec[] = [];
  schema.forEach((entry, index) => {
    const path = `variable_schema[${index}]`;
    if (!isPlainObject(entry)) {
      errors.push(`${path}: entry must be an object`);
      return;
    }
    for (const key of Object.keys(entry)) {
      if (key !== "key" && key !== "label" && key !== "required") {
        errors.push(`${path}: unsupported key "${key}"`);
      }
    }
    const { key, label, required } = entry;
    if (typeof key !== "string" || !TEMPLATE_VARIABLE_KEY_PATTERN.test(key)) {
      errors.push(`${path}: key must match /^[a-z][a-z0-9_]{0,63}$/`);
      return;
    }
    if (
      typeof label !== "string" ||
      label.trim().length === 0 ||
      label.length > TEMPLATE_VARIABLE_LABEL_MAX_LENGTH
    ) {
      errors.push(
        `${path}: label must be a non-empty string of at most ${TEMPLATE_VARIABLE_LABEL_MAX_LENGTH} characters`,
      );
      return;
    }
    if (typeof required !== "boolean") {
      errors.push(`${path}: required must be a boolean`);
      return;
    }
    if (seen.has(key)) {
      errors.push(`${path}: duplicate variable key "${key}"`);
      return;
    }
    seen.add(key);
    variables.push({ key, label, required });
  });
  if (errors.length > 0) {
    return { ok: false, errors };
  }
  return { ok: true, variables };
}

/**
 * Cross-checks the variables collected from a template's subject and body
 * against its declared `variable_schema` and returns the merged specs:
 * usage order first (subject, then body), then declared-only variables in
 * schema order. A variable is required when EITHER side marks it required.
 * A label conflict between a body node and the schema is an error.
 */
export function mergeWithDeclaredVariables(
  collected: readonly TemplateVariableSpec[],
  declared: readonly TemplateVariableSpec[],
  collectedSubjectOnlyKeys: ReadonlySet<string> = new Set(),
): VariablesResult {
  const errors: string[] = [];
  const declaredByKey = new Map(declared.map((spec) => [spec.key, spec]));
  const merged: TemplateVariableSpec[] = [];
  const seen = new Set<string>();
  for (const spec of collected) {
    const declaredSpec = declaredByKey.get(spec.key);
    let label = spec.label;
    let required = spec.required;
    if (declaredSpec !== undefined) {
      if (collectedSubjectOnlyKeys.has(spec.key)) {
        // Subject placeholders have no label of their own — schema wins.
        label = declaredSpec.label;
      } else if (declaredSpec.label !== spec.label) {
        errors.push(`conflicting labels for variable "${spec.key}"`);
      }
      required = required || declaredSpec.required;
    }
    merged.push({ key: spec.key, label, required });
    seen.add(spec.key);
  }
  for (const spec of declared) {
    if (!seen.has(spec.key)) {
      merged.push({
        key: spec.key,
        label: spec.label,
        required: spec.required,
      });
    }
  }
  if (errors.length > 0) {
    return { ok: false, errors };
  }
  return { ok: true, variables: merged };
}

/**
 * Full resolution for a template version: validates the body document, the
 * subject template, and the declared `variable_schema`, then cross-checks
 * and merges them. This is the single source of truth used by
 * `applyTemplate` and the variable form UI.
 */
export function resolveTemplateVariables(version: {
  subject_template: string;
  body_template_json: unknown;
  variable_schema: unknown;
}): VariablesResult {
  const body = validateTemplateDocument(version.body_template_json);
  if (!body.ok) {
    return body;
  }
  const declared = declaredVariables(version.variable_schema);
  if (!declared.ok) {
    return declared;
  }
  const collected = collectVariables(body.document, version.subject_template);
  if (!collected.ok) {
    return collected;
  }
  // Keys that appear only in the subject have no label of their own, so a
  // schema-declared label must win instead of being reported as a conflict.
  const bodyOccurrences: VariableOccurrence[] = [];
  collectBodyOccurrences(body.document.content, bodyOccurrences);
  const bodyKeys = new Set(bodyOccurrences.map((occurrence) => occurrence.key));
  const subjectOnlyKeys = new Set(
    collected.variables
      .map((spec) => spec.key)
      .filter((key) => !bodyKeys.has(key)),
  );
  return mergeWithDeclaredVariables(
    collected.variables,
    declared.variables,
    subjectOnlyKeys,
  );
}
