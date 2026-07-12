# ADR 0002: Supabase-backed draft lifecycle

- Status: Accepted
- Date: 2026-07-11
- Scope: Phase 2 (persistence, versions, templates, signatures, attachments)
- Builds on: ADR 0001 (canonical composer)

## Context

Phase 1 established Tiptap/ProseMirror JSON as the only editable source of
truth with derived HTML/plain-text outputs. Phase 2 adds persistence: drafts
live in Supabase (PostgreSQL + Auth + RLS + Storage), edited by workspace
members, with autosave, version history, templates, signatures, and private
attachments. Phase 2 explicitly excludes e-mail transport and AI.

## Decisions

### Current draft vs. immutable version model

A draft has exactly one mutable "current" row (`public.drafts`) and an
append-only history (`public.draft_versions`). Versions are immutable by
construction: no UPDATE grant or policy for `authenticated`, plus a trigger
that rejects UPDATEs outright. Normal users cannot delete versions; rows only
disappear through the parent draft's FK cascade. Restoration never rewrites
history — it copies a historical snapshot into the current row, increments
the revision, and appends a new `restore` version.

### Optimistic concurrency

Every draft carries a monotonically increasing `revision`. All writes go
through the `save_draft` / `restore_draft_version` RPCs, which lock the row
(`SELECT … FOR UPDATE`), compare the caller's `expected_revision` with the
stored value, and raise a dedicated SQLSTATE (`P0409`) on mismatch. The API
maps this to HTTP 409; the UI shows a visible conflict state with only safe
resolutions (reload remote / save as new draft / compare metadata). There is
no silent last-write-wins path anywhere.

### Autosave checkpoint policy

Autosave PATCHes the current row (debounced ~1.5 s client-side) but does not
create a version per keystroke. A version with reason `autosave_checkpoint`
is created only when content actually changed and the most recent version is
older than 10 minutes. Explicit checkpoints are always created: `initial` on
creation, `before_template`/`after_template`, `before_signature`/
`after_signature`, `manual_checkpoint`, and `restore`. Saving an identical
document is a no-op (no revision bump, no version) so history never fills
with duplicates.

### Restoration semantics

Restore requires the version to belong to the same draft AND workspace,
checkpoints the current state first (if it differs from the latest version),
copies the historical subject and canonical body into the current row,
increments the revision, and appends a `restore` version. All prior versions
are preserved.

### Template versioning and deterministic variables

Templates (`draft_templates`) are workspace-shared; their content lives in
immutable `draft_template_versions` (same immutability mechanics as draft
versions). Editing a template creates a new version; applying a template
records the exact version ID on the draft (`last_template_version_id`).

Template bodies use the Phase 1 canonical schema plus exactly one extra
inline node: `{ type: "variable", attrs: { key, label, required } }` with a
strict key format (`^[a-z][a-z0-9_]{0,63}$`). Subject templates use only
`{{key}}` placeholders parsed by a tiny deterministic scanner. There is no
eval, no Function, no helper execution, no expression language. Resolution
requires explicit values for every required variable ("ask or block; never
guess"): missing values yield a structured `missing_variables` error and the
template is not applied at all. Values are inserted as ordinary text nodes —
they can never introduce markup — and the resolved document must pass Phase 1
canonical validation before it is saved. Saved drafts therefore never contain
unresolved template syntax.

### Signature ownership

Signatures are personal: RLS restricts every command (including SELECT) to
`owner_user_id = auth.uid()` within the member's workspace. At most one
default per user per workspace is enforced by a partial unique index plus the
`set_default_signature` RPC. Signature bodies are canonical documents;
application is deterministic and duplicate-safe (an already-appended
signature block is detected and not appended twice), creates
`before_signature`/`after_signature` checkpoints, and never mutates the
signature record.

### Attachment verification

Attachment metadata (`draft_attachments`) starts as `pending`. The storage
path is derived server-side and enforced by a CHECK constraint to the exact
shape `workspace_id/draft_id/attachment_id/safe_filename`, so a row can never
point at another workspace's objects. A row may only become `ready` through
`finalize_attachment`, which verifies the Storage object actually exists at
the authorized path with a matching size; a database trigger additionally
rejects any direct `status='ready'` update without verification. Deletion
removes the Storage object first and marks the row `deleted` only when the
object is verifiably gone. Filenames are normalized server-side; MIME types
are allowlisted (pdf/png/jpeg/plain text — no HTML, no SVG); limits: 10 MiB
per file, 10 attachments per draft, 25 MiB per draft.

### Future MIME manifest

`renderDraftPackage(document, attachments)` extends — without changing — the
Phase 1 `renderDraft` contract: it returns the same derived HTML plus a
plain-text attachment list and a manifest of validated metadata
(`AttachmentManifestItem[]`). Only verified `ready` attachments appear;
pending/failed/deleted rows never do, and nothing is ever rendered claiming a
file is attached unless it is in the manifest. No SMTP, Nodemailer, or MIME
serialization is included; the manifest is the hand-off point for the future
Phase 3 transport worker.

### RLS design

Every new table has RLS enabled and uses the existing membership model
(`public.is_workspace_member(workspace_id)`), mirroring the production core
schema. INSERT/UPDATE policies verify both membership and `created_by =
auth.uid()` (or `owner_user_id = auth.uid()`), define both USING and WITH
CHECK, and freeze `workspace_id`, `created_by`, and `owner_user_id` via
triggers so records cannot be moved across workspaces or attributed to someone
else. `anon` has no grants on any Phase 2 table, and all RPCs revoke EXECUTE
from PUBLIC/anon.

**Corrective hardening (2026-07-12):** RLS alone did not enforce the lifecycle
invariants — a member could call PostgREST directly and bypass the RPCs
(rewrite `revision`, forge a version, flip an attachment to `ready`). The
mutation RPCs are therefore **SECURITY DEFINER** with a fixed `search_path`
and in-body authorization (assert `auth.uid()`, then re-check
`is_workspace_member`, raising `P0002` otherwise), and direct
`INSERT/UPDATE/DELETE` on the invariant-bearing tables (`drafts`,
`draft_versions`, `draft_template_versions`, `draft_attachments`) is revoked
from `authenticated` — they are **SELECT-only**, making the RPCs the sole write
path. `draft_templates` (INSERT/UPDATE) and `signatures` (INSERT/UPDATE/DELETE)
keep direct DML as deliberate exceptions with no cross-row invariant. The
policies above remain as defense in depth. See
`docs/security/phase-2-review.md` for the full rationale.

### Corrective hardening: two-migration strategy

The invariants above must hold even for an environment that already applied the
first Phase 2 migration before it was hardened. Rather than drop and recreate,
the fix ships as two migrations that converge on identical security-relevant
schema:

- `20260711130000_draft_lifecycle.sql` was **amended in place** so a fresh
  deploy is born secure (SECURITY DEFINER RPCs, SELECT-only grants);
- `20260712100000_enforce_phase2_rpc_invariants.sql` is an additive,
  idempotent migration that converges an environment which ran the _original_
  insecure version into the same state (drops the old INVOKER overloads,
  recreates the DEFINER RPCs, collapses grants, re-scopes the Storage INSERT
  policy to a matching pending intent).

`pnpm test:db` includes a migration-equivalence check proving
`baseline → amended` == `baseline → original → hardening` ==
`baseline → amended → hardening ×2` (the hardening migration is a re-runnable
no-op), so both deploy paths are provably equivalent and safe to re-run.

### Why the service role is prohibited in the UI

The UI operates exclusively as the authenticated user through the publishable
key. A service-role key would bypass RLS wholesale, so a single application
bug (or dependency compromise) would become a full data breach across every
workspace. There is deliberately no service-role environment variable in this
application; a repository boundary test suite (`phase2-boundaries.test.ts`,
run by CI) guards against reintroduction.

### Why the production migration is not automatic

The two Phase 2 migrations are deployable but NOT applied by this repository,
its CI, or this PR. Applying schema + RLS + grant changes to production is a
separate, explicitly approved operational step (see the production deployment
package in docs/security/phase-2-review.md): it changes authorization surfaces
(revokes direct DML, converts RPCs to SECURITY DEFINER) and creates a Storage
bucket, and must be verified with the documented pre-/post-deployment queries
by a human — including a fresh GO/NO-GO and dashboard confirmation of
backup/PITR posture. CI runs against an isolated local database initialized
from a non-deployable baseline snapshot of the current production schema.

### Rollback and disable strategy

`NEXT_PUBLIC_DRAFT_LIFECYCLE_V1_ENABLED` gates every Phase 2 page and API
route and defaults to disabled (fail closed). Setting it to anything but
"true" fully disables the surface without a code revert. Both database
migrations are additive-only; if the feature is rolled back at the application
layer the new tables simply sit unused. Destructive rollback of the schema
(dropping tables) is documented as a manual, data-loss operation that is not
part of the standard rollback path.

## Consequences

- All authorization lives in the database (RLS + grants); the API layer adds
  scoping and validation but never bypasses it.
- The local test harness runs on vanilla PostgreSQL with faithful
  auth/storage shims because this environment cannot run the full Supabase
  stack; PostgREST-level behavior is emulated by executing as the `anon`/
  `authenticated` roles with `request.jwt.claims` set, which is exactly the
  mechanism PostgREST uses. Running the same suites against a full
  `supabase start` stack is recorded as a backlog item.
