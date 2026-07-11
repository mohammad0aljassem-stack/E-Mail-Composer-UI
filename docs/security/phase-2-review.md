# Phase 2 security review

- Date: 2026-07-11
- Scope: Supabase-backed draft lifecycle (drafts, versions, templates,
  signatures, attachments, workspace-scoped APIs)
- Reviewed surfaces: database schema + RLS + grants, RPC functions, Storage,
  API routes, request handling, CSP, dependencies, CI

## RLS threat model

Assets: draft content, version history, templates, signatures, attachment
metadata. Adversaries: unauthenticated callers, authenticated users outside
the workspace, malicious members forging ownership, and clients talking to
PostgREST directly (bypassing our API).

Controls:

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
- `storage.objects` policies for the bucket scope SELECT/INSERT/DELETE to
  workspace members of the first path segment
  (`is_workspace_member(foldername(name)[1])`); there is no UPDATE policy.
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

- All Phase 2 RPCs are SECURITY INVOKER with `SET search_path = ''` — RLS
  applies inside them; no SECURITY DEFINER function was added in Phase 2.
- EXECUTE revoked from PUBLIC and anon; granted only to `authenticated`
  (service_role retains owner-level access).
- Revision conflicts raise SQLSTATE `P0409`; messages are content-free
  (structure/IDs only, never draft text), and hostile direct RPC calls
  (anon, non-member) are covered by the SQL test suites.

## SQL grants (reviewed separately from RLS)

- New tables: `authenticated` gets SELECT/INSERT/UPDATE/DELETE only where
  the feature needs it; version tables get SELECT/INSERT only; `anon` gets
  nothing. `TO authenticated` in a policy is understood as a filter, not an
  authorization grant — the grant matrix was reviewed on its own.
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
4. Attachment `sha256` is optional in Phase 2 (client-supplied when present);
   server-side content hashing belongs to the Phase 3 worker, which will
   read the objects anyway.
5. Sign-in UX is out of scope; all Phase 2 surfaces require an existing
   valid session and fail closed (401/404) without one.
