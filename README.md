# Email Composer UI

The Email Composer: a professional e-mail editor whose **only** editable
source of truth is Tiptap / ProseMirror JSON. Safe, e-mail-compatible HTML
and a plain-text alternative are **derived** on the server from that
canonical JSON — user-provided HTML is never stored or rendered directly.

Phase 1 delivered the isolated composer foundation; Phase 2 adds the
Supabase-backed draft lifecycle: persisted drafts with debounced autosave,
optimistic concurrency with visible conflict handling, immutable version
history and restore, workspace templates with deterministic variables,
personal signatures, and private verified attachments. See
[Excluded features](#excluded-features) for what remains out of scope.

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

## Feature flags

`.env.example` is **fail-closed**: every feature flag defaults to disabled.
To develop locally, copy it and enable what you need:

```bash
cp .env.example .env.local
# then set in .env.local:
NEXT_PUBLIC_COMPOSER_V1_ENABLED=true          # /composer-lab + /api/composer/render
NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED=true   # /w/[workspaceId]/drafts + /api/workspaces/**
```

Any other value (or unset) disables the surface: pages show a disabled
notice and the APIs return `404`. The flags are the **rollback switches** —
disabling them fully turns off the features without a code revert (see the
ADRs).

## Supabase setup (Phase 2)

Persisted drafts require a Supabase project (Auth + Postgres + Storage).
Only **public** values are configured in the app:

```
NEXT_PUBLIC_SUPABASE_URL=https://YOUR-PROJECT-ref.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

Never add a service-role or secret key to this application — the UI runs
entirely as the authenticated user through RLS. All persisted draft pages
and `/api/workspaces/**` routes require a valid Supabase Auth session
(unauthenticated calls get `401`); configuring an auth provider and sign-in
UX is outside this repository's scope.

### Local database, baseline, and the Phase 2 migration

The repo does not contain the historical migrations that created the
production core schema. Instead:

- `supabase/baseline/production_schema_2026_07_11.sql` — a **non-deployable**
  snapshot of the current production schema (test scaffolding only; see
  `supabase/baseline/README.md` for its checksum and provenance);
- `supabase/migrations/20260711130000_draft_lifecycle.sql` — the **only
  deployable** artifact of Phase 2 (additive).

Run the database + RLS test suite against an isolated local PostgreSQL
(no Docker required for the tests; PostgreSQL 16 binaries needed):

```bash
pnpm test:db          # throwaway cluster: baseline -> migration (applied
                      # twice, idempotency check) -> SQL test suites
pnpm gen:types        # regenerate src/lib/supabase/database.types.ts
                      # (needs DB_URL and Docker; see scripts/gen-types.sh)
```

`src/lib/supabase/database.types.ts` is **generated** by the official
Supabase CLI (`supabase gen types typescript --db-url ...`) from the local
post-migration schema — never hand-edited, never generated from
production. Generation needs a Docker daemon because the CLI runs
postgres-meta in a container.

CI's database job replays the same pipeline and enforces both gates:
it loads the baseline, applies the Phase 2 migration twice (idempotency),
runs the SQL/RLS suites, then regenerates the types from that exact
schema and **fails on any byte-level drift** from the committed file
("Verify generated database types are current"). **The production
migration is never applied automatically** — production deployment is a
separate, explicitly approved operational step (see
`docs/security/phase-2-review.md`).

## Draft lifecycle (Phase 2)

- Routes: `/w/[workspaceId]/drafts` (list + create) and
  `/w/[workspaceId]/drafts/[draftId]` (editor).
- **Autosave**: debounced (~1.5 s), no save per keystroke, skipped when the
  content is unchanged; explicit actions flush pending saves; stale requests
  are cancelled. Save state is always visible: Unsaved / Saving / Saved /
  Offline / Conflict / Save failed.
- **Conflicts**: every save carries the expected revision; a mismatch is
  HTTP 409 and surfaces a visible conflict dialog with only safe choices —
  reload the remote version, save your editor content as a new draft, or
  compare metadata. There is no silent overwrite.
- **Version history**: immutable checkpoints (initial, autosave checkpoints
  at most every 10 minutes, manual, before/after template and signature,
  restore). Restoring copies a historical snapshot into the current draft as
  a **new** revision — history is never rewritten.
- **Templates**: workspace-shared with immutable versions; bodies may
  contain `variable` nodes and subjects `{{key}}` placeholders. Application
  requires explicit values for all required variables (missing values block
  with a structured list — nothing is ever guessed) and records the exact
  template version used.
- **Signatures**: personal per user and workspace (invisible to peers), at
  most one default each, deterministic duplicate-safe application.
- **Attachments**: private Supabase Storage bucket `draft-attachments`
  (never public). Lifecycle: pending intent → authenticated upload to a
  server-authorized path → verified finalization (object existence + size
  checked) → `ready`. Only `ready` attachments appear in previews and the
  future MIME manifest; deletion removes the object first. Limits: pdf, png,
  jpeg, txt only; 10 MiB/file; 10 files and 25 MiB per draft.

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
