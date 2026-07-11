/**
 * Centralized link safety policy.
 *
 * Only absolute http:, https: and mailto: URLs are allowed anywhere in the
 * canonical document. Everything else — javascript:, data:, vbscript:,
 * file:, protocol-relative URLs, and relative URLs — is rejected.
 *
 * This is the single place where URL policy lives; editor, validation and
 * rendering all import from here instead of duplicating checks.
 */

const ALLOWED_PROTOCOLS: ReadonlySet<string> = new Set([
  "http:",
  "https:",
  "mailto:",
]);

/**
 * Browsers strip ASCII control characters before parsing a URL's scheme,
 * which attackers exploit with values like "java\tscript:alert(1)". We strip
 * the same range before making any decision.
 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/g;

/**
 * Returns the normalized absolute URL when the input is safe, or null when
 * it must be rejected. Never throws.
 */
export function normalizeHref(raw: unknown): string | null {
  if (typeof raw !== "string") {
    return null;
  }
  const cleaned = raw.replace(CONTROL_CHARS, "").trim();
  if (cleaned.length === 0) {
    return null;
  }
  // Protocol-relative URLs inherit the scheme of the viewing context and
  // are not explicitly normalized — rejected.
  if (cleaned.startsWith("//")) {
    return null;
  }
  let url: URL;
  try {
    url = new URL(cleaned);
  } catch {
    // Relative URLs are meaningless inside an e-mail — rejected.
    return null;
  }
  if (!ALLOWED_PROTOCOLS.has(url.protocol.toLowerCase())) {
    return null;
  }
  return url.href;
}

/** True when the value is an allowed http:, https: or mailto: URL. */
export function isSafeHref(raw: unknown): boolean {
  return normalizeHref(raw) !== null;
}
