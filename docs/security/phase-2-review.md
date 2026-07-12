# Phase 2 security review

- Date: 2026-07-11 (updated 2026-07-12 after corrective hardening)
- Scope: Supabase-backed draft lifecycle (drafts, versions, templates,
  signatures, attachments, workspace-scoped APIs)
- Reviewed surfaces: database schema + RLS + grants, RPC functions, Storage,
  API routes, request handling, CSP, dependencies, CI

## Corrective hardening (2026-07-12)

The original Phase 2 migration shipped its mutation RPCs as SECURITY INVOKER
and granted `authenticated` direct `INSERT/UPDATE/DELETE` on the draft,
template-version, and attachment tables. **RLS alone did not enforce the
lifecycle invariants**: a member could talk to PostgREST directly and bypass
every RPC (rewrite `revision` without the optimistic-concurrency check, flip an
attachment to `status='ready'` without verification, forge a `draft_versions`
row, move the `last_template_version_id` pointer, etc.). RLS answers "may this
row be touched by this member" — it cannot answer "was this touched through the
one code path that preserves the invariant." Those are different questions.

The fix (two migrations — see below) makes the RPCs the **only** write path:

- mutation RPCs became **SECURITY DEFINER** with in-body authorization;
- direct table privileges collapsed to **SELECT-only** (plus the narrow
  `draft_templates` INSERT/UPDATE and `signatures` INSERT/UPDATE/DELETE
  exceptions, which have no cross-row invariant to protect);
- the Storage INSERT policy was re-scoped to a matching pending intent row,
  preventing arbitrary-path and post-`ready` replacement uploads.

Two-migration strategy: `20260711130000_draft_lifecycle.sql` was **amended in
place** so a fresh deploy is born secure, and a separate additive, idempotent
`20260712100000_enforce_phase2_rpc_invariants.sql` converges any environment
that already ran the original insecure version. `pnpm test:db` proves the two
deploy paths reach byte-identical security-relevant schema (equivalence check).

## RLS threat model

Assets: draft content, version history, templates, signatures, attachment
metadata. Adversaries: unauthenticated callers, authenticated users outside
the workspace, malicious members forging ownership, and clients talking to
PostgREST directly (bypassing our API).

Controls (note: after the 2026-07-12 hardening the INSERT/UPDATE policies
below are **defense in depth** for the invariant-bearing tables — direct
`INSERT/UPDATE/DELETE` is revoked from `authenticated`, so those writes only
ever happen inside the SECURITY DEFINER RPCs; the policies still hold if a
grant were ever mistakenly restored):

- RLS enabled on every Phase 2 table; row access derives from
  `public.is_workspace_member(workspace_id)` — the same battle-tested
  membership helpers production already uses (SECURITY DEFINER, STABLE,
  fixed search_path, EXECUTE revoked from anon).
- INSERT policies require membership AND `created_by = auth.uid()`
  (signatures: `owner_user_id = auth.uid()`); forged attribution is rejected
  at the policy level, and triggers freeze `workspace_id`/`created_by`/
  `owner_user_id` on UPDATE so records cannot be moved or re-attributed.
- UPDATE policies define both USING and WITH CHECK.
- Signatures are private per user: SELECT is owner-scoped, so workspace
  peers cannot enumerate or read another member's signatures.
- Version tables are immutable: no UPDATE/DELETE grants or policies for
  `authenticated` plus an unconditional reject-update trigger.
- `anon` has zero grants on Phase 2 tables and cannot execute any Phase 2
  RPC (EXECUTE revoked from PUBLIC and anon).
- Authorization never reads `auth.role()` or user-editable metadata
  (`raw_user_meta_data` is only copied to `public.users.full_name` by the
  pre-existing signup trigger, never used for decisions).
- Tests exercise these paths as PostgREST would execute them: as the
  `anon`/`authenticated` roles with `request.jwt.claims` set. This matches
  PostgREST's execution model; testing through an actual PostgREST instance
  requires running the full Supabase stack (`supabase start`) and is a
  recorded backlog item — CI uses Docker only for type generation
  (postgres-meta), not for a full-stack run.

## Storage threat model

Assets: attachment file contents in the private `draft-attachments` bucket.

Controls:

- Bucket is private (`public=false`), with a 10 MiB server-side size limit
  and a MIME allowlist (pdf/png/jpeg/plain text) at the bucket level as well
  as in metadata constraints.
- `storage.objects` SELECT/DELETE policies for the bucket scope to workspace
  members of the first path segment
  (`is_workspace_member(foldername(name)[1])`); there is no UPDATE policy.
- **Object replacement prevention (hardened):** the INSERT policy no longer
  trusts the path prefix alone. An upload is allowed only while a matching
  `draft_attachments` intent row exists with the same `storage_path`,
  `status='pending'`, `created_by = auth.uid()`, and a workspace the caller
  belongs to. This blocks arbitrary-path, wrong-workspace, wrong-draft, and —
  because `finalize_attachment` moves the row off `pending` — post-`ready`
  replacement re-uploads. An attacker cannot overwrite a verified object.
- The metadata row's `storage_path` is constrained by CHECK to
  `workspace_id/draft_id/attachment_id/safe_filename`, so metadata can never
  reference another workspace's prefix.
- No public URLs are ever created; downloads would use short-lived signed
  URLs generated only after authorization (not implemented in this phase).
- "Ready" is verification-gated: `finalize_attachment` confirms the object
  exists at the authorized path with a matching size, and a trigger rejects
  direct `status='ready'` updates. Deletion removes the object first; the
  row is marked deleted only when the object is verifiably gone, so the UI
  can never claim a file is attached that is not actually present.

## Function security

- The Phase 2 **mutation** RPCs (`create_draft`, `save_draft`,
  `checkpoint_draft`, `restore_draft_version`, `archive_draft`,
  `create_template_version`, `create_attachment_intent`,
  `finalize_attachment`, `mark_attachment_deleted`) are **SECURITY DEFINER**
  with `SET search_path = ''`. They are the only write path to the tables
  whose invariants must hold (revision monotonicity + optimistic concurrency,
  immutable append-only versions, verification-gated attachment `ready`,
  server-authorized storage paths, traceability pointers). SECURITY DEFINER is
  required precisely because those tables are SELECT-only for `authenticated`
  (see grants) — the function owner supplies the write privilege while the
  function body supplies the authorization.
- **Per-RPC authorization is enforced in-body and never trusts client
  identity.** Every mutation RPC first asserts `auth.uid() IS NOT NULL`
  (else `42501`), then re-checks workspace membership with the same
  `public.is_workspace_member()` helper used by RLS, raising SQLSTATE `P0002`
  ("… not found or access denied") on a non-member or missing row. Because the
  check is inside the DEFINER body, RLS being bypassed by the elevated owner is
  irrelevant — the membership predicate runs unconditionally on every call.
- `set_default_signature` stays SECURITY INVOKER (signatures are owner-scoped
  direct DML with no cross-row invariant); the two shared helper functions
  (`phase2_safe_filename`, `phase2_validate_variable_schema`) are INVOKER and
  have EXECUTE revoked from `authenticated` entirely (called only from within
  DEFINER bodies).
- EXECUTE on the callable RPCs is revoked from PUBLIC and anon; granted only to
  `authenticated` (service_role retains owner-level access).
- Revision conflicts raise SQLSTATE `P0409` with `hint = 'current_revision=N'`
  so PostgREST surfaces the current revision to the API (mapped to HTTP 409
  with `currentRevision`). Messages are content-free (structure/IDs only, never
  draft text); `P0002` is mapped by the API to a uniform 404. Hostile direct
  RPC calls (anon, non-member) and direct-DML bypass attempts are covered by
  the SQL test suites (`grant_matrix`, `direct_write_regression`).

## SQL grants (reviewed separately from RLS)

- Direct privileges on the invariant-bearing tables (`drafts`,
  `draft_versions`, `draft_template_versions`, `draft_attachments`) collapse to
  **SELECT-only** for `authenticated`; all `INSERT/UPDATE/DELETE` were
  `REVOKE`d **from `authenticated`** (not merely from anon/public), which also
  defeats any inherited default-ACL privilege. Writes to these tables happen
  exclusively through the SECURITY DEFINER RPCs.
- Narrow, deliberate exceptions with no cross-row invariant: `draft_templates`
  keeps direct `INSERT/UPDATE` (template creation is a plain RLS-guarded
  insert) and `signatures` keeps `INSERT/UPDATE/DELETE` (owner-scoped, private
  per user). These are documented as intentional, not oversights.
- `anon` gets nothing on any Phase 2 table. `service_role` retains full access
  but is never present in this application (no service-role key exists).
- `TO authenticated` in a policy is understood as a filter, not an
  authorization grant — the grant matrix was reviewed on its own and is
  regression-tested (`grant_matrix.test.sql`).
- Pre-existing production grants (broad table grants gated by RLS) were left
  untouched; Phase 2 does not widen any existing grant.

## Cross-workspace isolation tests

The SQL suites cover: anon isolation, same-workspace shared access,
out-of-workspace invisibility (0 rows, no existence signal), workspace-move
rejection, forged `created_by` rejection, signature privacy between peers,
Storage prefix isolation, and unauthorized RPC execution. The API layer adds
uniform 404s so "not yours" and "does not exist" are indistinguishable.

## Request streaming limit (Phase 1 debt fixed)

`readJsonBodyWithLimit` replaces `await request.text()`: it rejects oversized
declared Content-Length before reading, reads the stream incrementally,
cancels the reader the moment the byte budget is exceeded (including
chunked bodies without Content-Length), decodes UTF-8 leniently, and returns
structured errors. It is used by the Phase 1 render route and every Phase 2
JSON route. Tests include an endless chunked stream that must be stopped
early.

## CSP status

Unchanged from Phase 1 — not weakened, no new origins, no production
`unsafe-eval`. Nonce-based `script-src` hardening was investigated: Next.js
supports nonces via middleware that sets a per-request CSP header and
propagates `x-nonce`, but it forces dynamic rendering of currently static
pages and interacts with the sandboxed `srcDoc` e-mail preview (which
inherits the parent CSP and relies on inline styles by design). That
trade-off was judged too fragile for this PR. Recorded security backlog:
introduce nonce-based `script-src` (and drop `'unsafe-inline'`) once the
app's pages are intentionally dynamic; keep `style-src 'unsafe-inline'`
scoped to the e-mail preview's isolation boundary (empty `sandbox` iframe),
which remains the actual containment mechanism for rendered e-mail HTML.

## Secrets and keys

- Only `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
  are consumed; both are public by design.
- No service-role key exists anywhere in the repository, environment
  examples, or CI; tests grep the source for service-role patterns.
- `.env` files are gitignored; `.env.example` contains placeholders only and
  is fail-closed (all feature flags default off).

## Known remaining security debt

1. CSP `script-src 'unsafe-inline'` (see above) — backlog item with a
   documented plan; `style-src 'unsafe-inline'` is required by e-mail inline
   styles and contained by the sandboxed preview.
2. RLS/PostgREST behavior is tested via role + `request.jwt.claims`
   emulation on vanilla PostgreSQL; a full-stack `supabase start` test run
   in CI (which already has Docker) is a follow-up item.
3. The moderate `postcss <8.5.10` advisory (transitive via Next.js) remains
   below the high/critical gate and is tracked until Next bumps it.
4. Attachment `sha256` is **client-supplied and unverified** in Phase 2:
   `finalize_attachment` verifies object existence and size at the authorized
   path, but it does **not** recompute the digest, so a stored `sha256` is a
   convenience hint, not an integrity guarantee. Trustworthy server-side
   content hashing belongs to the Phase 3 transport worker, which reads the
   object bytes anyway. Nothing in Phase 2 makes a trust decision based on the
   client-supplied hash.
5. **Attachment garbage collection is not yet implemented and is a
   feature-enablement gate.** A pending intent whose upload never completes
   (or an object uploaded against an intent that is never finalized) leaves an
   orphaned `pending` row and/or an unreferenced storage object. Nothing
   currently reaps them. A scheduled GC worker (expire stale `pending` intents,
   delete objects with no live `ready` row) must land before the feature is
   enabled beyond a controlled cohort — the fail-closed feature flag is the
   interim control.
6. Sign-in UX is out of scope; all Phase 2 surfaces require an existing
   valid session and fail closed (401/404) without one.

## Production readiness (still blocked)

- **Production remains blocked pending a fresh GO/NO-GO.** This review covers
  the code and the local/CI-verified schema only. Enabling the feature in
  production requires a new decision after the migrations are applied and the
  GC gate (item 5) is resolved; CI never applies the migrations to production.
- **Backup / PITR posture requires human confirmation in the Supabase
  dashboard.** Point-in-time recovery and backup retention for the target
  project cannot be asserted from this repository; a human must confirm the
  dashboard settings before the migrations run against production, so that the
  first RPC-only cutover is recoverable.
