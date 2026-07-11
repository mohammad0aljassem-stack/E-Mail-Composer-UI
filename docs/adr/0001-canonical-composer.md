# ADR 0001: Canonical email composer

- Status: Accepted
- Date: 2026-07-11
- Scope: Phase 1 (isolated composer foundation)

## Context

The Email Composer needs a document format that is safe to store, edit
collaboratively in the future, render into e-mail-compatible HTML, and reason
about programmatically. E-mail HTML is famously inconsistent and a large XSS
surface, so we must not let user-provided HTML become the document of record.

## Decision

### Tiptap / ProseMirror JSON is the single source of truth

The canonical, editable document is Tiptap/ProseMirror JSON, stored and
transported as JSON. It is a structured tree with a schema we fully control,
which makes validation, normalization, diffing, and (later) partial edits
tractable. The editor's schema is the first line of defense: only the allowed
nodes and marks exist, so pasted HTML is reduced to that subset by
ProseMirror's schema-driven parsing — raw HTML can never enter the document.

### HTML is derived, never stored as source

HTML and plain text are **outputs** produced from the canonical JSON. We never
store user-provided HTML as the canonical document, and we never edit HTML and
feed it back as the source. This guarantees "what you preview is what is sent"
and removes an entire class of HTML-injection bugs.

### React Email rendering is server-side

Rendering runs on the server via `@react-email/render` and React Email
components (`src/server/render`). React escapes all text children by default,
and the template never uses `dangerouslySetInnerHTML` for user content. Running
server-side keeps rendering deterministic, keeps the (future) heavier
dependencies off the client, and gives us one trusted place to apply the
output-side sanitizer as defense in depth.

### Allowed nodes and marks (v1)

Nodes: `doc`, `paragraph`, `text`, `bulletList`, `orderedList`, `listItem`,
`blockquote`, `hardBreak`.

Marks: `bold`, `italic`, `link`.

Disallowed: raw HTML nodes, images, tables, videos, iframes, scripts,
user-defined styles, arbitrary attributes, and unsupported protocols.

**Policy for invalid content.** Unsupported nodes, marks, keys, and attributes
are **rejected, not silently dropped**: `validateDraftDocument` reports them and
`normalizeDraftDocument` throws a `DraftValidationError`. The one deliberate
exception is an unsafe link href: normalization **removes the link mark but
keeps the visible text**, because dropping the user's words would be
surprising, whereas dropping an unusable/dangerous link is expected. This
exception is covered by tests.

Normalization is deterministic and idempotent and never mutates its input; the
render step likewise never mutates the document it is given.

### URL policy

All URLs flow through a single function, `normalizeHref`
(`src/lib/composer/links.ts`). Allowed protocols: `https:`, `http:`, `mailto:`.
Rejected: `javascript:`, `data:`, `vbscript:`, `file:`, protocol-relative
(`//host`) URLs, and relative URLs. ASCII control characters are stripped before
parsing to defeat scheme-smuggling such as `java\tscript:`. Centralizing this
avoids the classic bug of one forgotten URL check.

### Sanitization strategy (defense in depth)

The canonical pipeline (schema + validation + React escaping) already
guarantees no user markup reaches the output. On top of that, generated HTML
passes through `sanitize-html` (`src/server/render/sanitize.ts`) against a small
allowlist of e-mail tags/attributes and the same URL scheme allowlist. If a bug
upstream ever let markup through, nothing outside the allowlist — no scripts,
iframes, event handlers, or unsafe URLs — can survive.

### Preview isolation

The laboratory renders generated HTML inside an `<iframe>` with an **empty
`sandbox` attribute**. That disables scripts, forms, popups, top-level
navigation, and same-origin access, so previewing hostile content cannot affect
the app.

### Security-header tradeoff

Security headers are set in `next.config.ts`: `Content-Security-Policy`,
`X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options: DENY`,
and CSP `frame-ancestors 'none'`.

Two deliberate CSP relaxations:

- `style-src 'unsafe-inline'` is required because e-mail HTML uses **inline
  styles by design**, and the sandboxed preview iframe (populated via `srcDoc`)
  inherits the parent CSP. Without inline styles the intentional preview would
  render unstyled. The preview's empty `sandbox` attribute is what actually
  contains it, not CSP.
- `script-src 'unsafe-inline'` is kept because Next.js emits inline bootstrap
  scripts without a nonce pipeline in this phase; `'unsafe-eval'` is added in
  development only (React Fast Refresh). Tightening `script-src` with nonces is
  deferred to a later phase and does not affect the security of the canonical
  pipeline, which never emits user scripts.

### Why AI and e-mail transport are excluded

Phase 1 is the isolated composer foundation. Introducing AI or e-mail transport
here would combine two high-risk surfaces in one change and violate the
architecture rules (no AI-to-action/-send path, no IMAP/SMTP/Gmail/Graph, no
provider SDKs). They are separate, later phases with their own reviews.

### Rollback through the feature flag

The entire v1 surface is gated by `NEXT_PUBLIC_COMPOSER_V1_ENABLED`. Setting it
to anything other than `true` disables the `/composer-lab` page and makes
`/api/composer/render` return `404`, without a code revert. This is the
rollback plan for the phase.

## Consequences

- Strong safety and determinism, at the cost of a richer editor (no images or
  tables yet) — acceptable for the foundation.
- One canonical format to evolve; new node/mark types require a schema +
  validation + renderer + test change, which is the point.
- `localStorage` in the lab is a development demonstration only, storing
  canonical JSON — never generated HTML — under a versioned key. It is not
  production persistence.
