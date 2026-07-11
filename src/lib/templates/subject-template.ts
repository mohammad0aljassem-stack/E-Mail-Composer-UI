/**
 * Subject templates.
 *
 * The ONLY templating syntax is `{{key}}`, parsed by a tiny deterministic
 * scanner. No expressions, no nesting, no helpers, no dynamic code. Unknown
 * or malformed placeholders are validation errors — never silently ignored.
 *
 * Single `{` and `}` characters outside a `{{` opener are ordinary text.
 */

import { TEMPLATE_VARIABLE_KEY_PATTERN } from "@/lib/phase2/contracts";

export type SubjectToken =
  { kind: "text"; value: string } | { kind: "variable"; key: string };

/**
 * Parse errors are structured strings of the form
 * `subject[<index>]: <message>` where `<index>` is the zero-based position
 * of the offending `{{` in the subject template. They never echo user text.
 */
export type SubjectParseResult =
  { ok: true; tokens: SubjectToken[] } | { ok: false; errors: string[] };

export type RenderSubjectResult =
  | { ok: true; subject: string }
  | { ok: false; errors: string[]; missingVariables: string[] };

/**
 * Parses a subject template into a deterministic token list.
 * Strict: an unclosed `{{` or a key that does not match
 * /^[a-z][a-z0-9_]{0,63}$/ produces a structured error.
 */
export function parseSubjectTemplate(subject: string): SubjectParseResult {
  const tokens: SubjectToken[] = [];
  const errors: string[] = [];
  let text = "";
  let index = 0;
  const flush = (): void => {
    if (text.length > 0) {
      tokens.push({ kind: "text", value: text });
      text = "";
    }
  };
  while (index < subject.length) {
    if (subject.startsWith("{{", index)) {
      const close = subject.indexOf("}}", index + 2);
      if (close === -1) {
        errors.push(`subject[${index}]: unclosed variable placeholder`);
        break;
      }
      const key = subject.slice(index + 2, close);
      if (!TEMPLATE_VARIABLE_KEY_PATTERN.test(key)) {
        errors.push(
          `subject[${index}]: variable key must match /^[a-z][a-z0-9_]{0,63}$/ with no surrounding whitespace`,
        );
      } else {
        flush();
        tokens.push({ kind: "variable", key });
      }
      index = close + 2;
    } else {
      text += subject[index];
      index += 1;
    }
  }
  if (errors.length > 0) {
    return { ok: false, errors };
  }
  flush();
  return { ok: true, tokens };
}

/**
 * Renders a subject template with the given values. Deterministic join of
 * the parsed tokens; every placeholder must have a value entry (an explicit
 * empty string is a value — an absent key is a missing variable, and no
 * default is ever invented). Values are inserted verbatim; `{{` sequences
 * inside a value are NOT re-parsed.
 */
export function renderSubject(
  subject: string,
  values: Record<string, string>,
): RenderSubjectResult {
  const parsed = parseSubjectTemplate(subject);
  if (!parsed.ok) {
    return { ok: false, errors: parsed.errors, missingVariables: [] };
  }
  const missing: string[] = [];
  const parts: string[] = [];
  for (const token of parsed.tokens) {
    if (token.kind === "text") {
      parts.push(token.value);
    } else if (Object.hasOwn(values, token.key)) {
      parts.push(values[token.key] as string);
    } else if (!missing.includes(token.key)) {
      missing.push(token.key);
    }
  }
  if (missing.length > 0) {
    return {
      ok: false,
      errors: missing.map((key) => `missing value for variable "${key}"`),
      missingVariables: missing,
    };
  }
  return { ok: true, subject: parts.join("") };
}
