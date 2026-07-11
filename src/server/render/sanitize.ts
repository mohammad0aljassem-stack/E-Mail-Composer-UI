/**
 * Final output firewall for generated e-mail HTML.
 *
 * The canonical pipeline (schema validation + React escaping) already
 * guarantees that no user-controlled markup reaches the output. This module
 * adds defense in depth: even if a bug upstream ever let markup through,
 * nothing outside this allowlist — no scripts, iframes, event handlers or
 * unsafe URL schemes — can survive into the rendered e-mail.
 */

import sanitizeHtml from "sanitize-html";

const DOCTYPE_PATTERN = /^\s*<!doctype[^>]*>/i;

const OPTIONS: sanitizeHtml.IOptions = {
  allowedTags: [
    "html",
    "head",
    "body",
    "meta",
    "title",
    "table",
    "tbody",
    "tr",
    "td",
    "p",
    "a",
    "ul",
    "ol",
    "li",
    "blockquote",
    "strong",
    "em",
    "br",
    "div",
    "span",
    "hr",
  ],
  allowedAttributes: {
    "*": [
      "style",
      "dir",
      "lang",
      "align",
      "width",
      "cellpadding",
      "cellspacing",
      "border",
      "role",
    ],
    meta: ["charset", "content", "http-equiv", "name"],
    a: ["href", "target", "rel"],
    ol: ["start"],
  },
  allowedSchemes: ["http", "https", "mailto"],
  allowProtocolRelative: false,
  disallowedTagsMode: "discard",
};

/**
 * Sanitizes generated e-mail HTML against the allowlist above. The doctype
 * is preserved (sanitize-html drops directives). Deterministic.
 */
export function sanitizeEmailHtml(html: string): string {
  const doctype = html.match(DOCTYPE_PATTERN)?.[0] ?? "";
  return doctype + sanitizeHtml(html, OPTIONS);
}
