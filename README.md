# Email Composer UI

Phase 1 of the Email Composer: a professional e-mail editor whose **only**
editable source of truth is Tiptap / ProseMirror JSON. Safe, e-mail-compatible
HTML and a plain-text alternative are **derived** on the server from that
canonical JSON — user-provided HTML is never stored or rendered directly.

This repository contains the isolated composer foundation only. See
[Excluded features](#excluded-features) for what is deliberately out of scope.

## Scope

- A Tiptap-based editor limited to a small, safe node/mark set.
- A canonical document model with strict validation and deterministic,
  idempotent normalization.
- Centralized link-safety policy (`https:`, `http:`, `mailto:` only).
- Server-side rendering of the canonical JSON into e-mail HTML (React Email)
  and plain text.
- A development-only preview API and an isolated **composer laboratory** page.
- Security controls, automated tests, and CI.

## Prerequisites

- Node.js `>= 22`
- [pnpm](https://pnpm.io/) `10.x` (the repo pins `pnpm@10.33.0` via
  `packageManager`; run `corepack enable` to use it automatically)

## Installation

```bash
pnpm install --frozen-lockfile
cp .env.example .env.local   # then review the flag below
```

Never commit a real `.env` file. Only `.env.example` is tracked.

## Development commands

```bash
pnpm dev            # start the Next.js dev server
pnpm build          # production build
pnpm start          # serve the production build
```

Open <http://localhost:3000/composer-lab> for the composer laboratory.

## Test & quality commands

```bash
pnpm format:check   # Prettier formatting check
pnpm lint           # ESLint (next/core-web-vitals + next/typescript)
pnpm typecheck      # tsc --noEmit (strict mode)
pnpm test           # Vitest run
pnpm test:coverage  # Vitest with coverage thresholds
pnpm build          # Next.js production build
```

Coverage thresholds are enforced for the critical modules: canonical
validation, link safety, plain-text generation, server rendering, and the
render API.

## Feature flag

The composer v1 surface (the `/composer-lab` page and the
`/api/composer/render` endpoint) is gated behind a single environment
variable:

```
NEXT_PUBLIC_COMPOSER_V1_ENABLED=true
```

- Set it to `true` to enable the feature.
- Any other value (or unset) disables the page and makes the API return `404`.

This flag is the **rollback switch**: setting it to `false` fully disables the
new surface without reverting code. See
[`docs/adr/0001-canonical-composer.md`](docs/adr/0001-canonical-composer.md).

## Canonical document design

Tiptap/ProseMirror JSON is the canonical, editable document. HTML and plain
text are outputs derived from it and are never treated as sources.

**Allowed nodes (v1):** `doc`, `paragraph`, `text`, `bulletList`,
`orderedList`, `listItem`, `blockquote`, `hardBreak`.

**Allowed marks (v1):** `bold`, `italic`, `link`.

Everything else — raw HTML nodes, images, tables, videos, iframes, scripts,
user-defined styles, arbitrary attributes, and unsupported URL protocols — is
rejected by validation. Unsupported nodes and marks are **never dropped
silently**: strict validation reports them and `normalizeDraftDocument` throws.
Unsafe link hrefs are the one documented exception: the link mark is removed
while the visible text survives (see the ADR).

Links may only use `https:`, `http:`, or `mailto:`. `javascript:`, `data:`,
`vbscript:`, `file:`, and protocol-relative URLs are rejected by the single
`normalizeHref` policy in `src/lib/composer/links.ts`.

## Directory structure

```
src/
  app/
    page.tsx                     # landing page
    composer-lab/page.tsx        # isolated development laboratory
    api/composer/render/route.ts # dev-only preview endpoint (JSON in, {html,text} out)
  components/composer/
    ComposerEditor.tsx           # Tiptap editor (client)
    ComposerToolbar.tsx          # accessible formatting toolbar
    ComposerPreview.tsx          # sandboxed HTML + plain-text preview
    ComposerJsonPanel.tsx        # live canonical JSON
    ComposerLab.tsx              # lab page composition + localStorage demo
    editorExtensions.ts          # Tiptap schema (safe node/mark subset)
  lib/composer/
    canonical.ts                 # canonical model, validation, normalization
    links.ts                     # centralized URL policy
    plain-text.ts                # deterministic plain-text rendering
    samples.ts                   # Arabic + German sample document
  server/render/
    DraftEmail.tsx               # React Email template
    renderDraft.ts               # server-only render entrypoint
    sanitize.ts                  # output-side HTML firewall (defense in depth)
  tests/                         # Vitest suites
docs/adr/0001-canonical-composer.md
THIRD_PARTY_NOTICES.md
```

## Language direction (RTL/LTR)

The editor is not forced into RTL. Each paragraph and list item uses
`dir="auto"`, so Arabic, German, and mixed content stay readable, while the
rendered e-mail document root stays LTR (the German business-e-mail default).

## Excluded features

This phase intentionally does **not** include, and this repository must not
add:

- authentication, workspaces, or multi-tenant logic;
- e-mail sync, sending, IMAP, SMTP, Gmail, or Microsoft Graph;
- AI providers, AI SDKs, or any AI-to-action / AI-to-send path;
- Supabase packages or any production database integration;
- OCR, tasks, reminders, or notifications;
- Redis, BullMQ, QStash, Make, or n8n;
- raw HTML nodes in the editor schema;
- secrets, API keys, real credentials, or production endpoints.

GitHub Actions is used for CI checks only — never as an application runtime or
scheduler.
