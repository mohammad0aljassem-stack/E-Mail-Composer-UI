# Phase 3A security review — transport foundation

- Date: 2026-07-12
- Scope: Supabase-backed transport foundation (mailboxes, folder/message sync
  metadata, draft mirrors, confirmed send intents, outbound state machine,
  content-free audit) plus the private worker-only schema holding encrypted
  credentials and worker lease/heartbeat rows.
- Deliverable: one additive migration
  `supabase/migrations/20260713100000_transport_foundation.sql`, applied after
  the Phase 2 chain (`20260711130000_draft_lifecycle` +
  `20260712100000_enforce_phase2_rpc_invariants`).
- Production status: **still disabled.** This migration has NOT been applied to
  production (prod tip remains `20260709182252`; Phase 2 itself is not deployed
  yet). This is local-only schema work; the lead integrates.

## The core decision: two schemas, one trust boundary

The single most important control in Phase 3A is the split between what the
browser may read and what only the worker may touch.

- **`public.*` — workspace-facing metadata.** RLS-protected, reachable through
  PostgREST. `authenticated` gets **SELECT only**; there is **no** direct
  INSERT/UPDATE/DELETE path for the browser on any Phase 3 table. Every write is
  either a `SECURITY DEFINER` RPC or a worker-only mutation. These tables carry
  **no secrets and no message bodies** — only non-secret config, header/summary
  metadata, hashes, and content-free audit events.
- **`transport.*` — a PRIVATE schema.** Not exposed to PostgREST. `anon` and
  `authenticated` have **zero** access: no schema `USAGE`, no table privileges.
  The schema is explicitly locked down
  (`revoke all on schema transport from public, anon, authenticated`) and
  `USAGE` is granted only to `transport_worker` and `service_role`. Credential
  ciphertext, nonce, auth tag, key version, and worker lease/heartbeat rows live
  here and **can never reach the browser**.

Why not one schema with RLS? Because a browser JWT reaching PostgREST can query
any `public` table it has a SELECT grant + policy for. Credentials must be
categorically unreachable, not merely filtered — so they live in a schema the
browser role cannot even name (`permission denied for schema transport`, tested
in `transport_rls.test.sql`).

## Tables

### public (RLS on; members SELECT within their workspace)

| Table | Purpose | Secrets? |
|-------|---------|----------|
| `mailboxes` | Mailbox metadata + non-secret IMAP/SMTP host/port/security config, `enabled`, `kill_switch` | No passwords |
| `mailbox_folders` | Discovered folders + safe-to-expose sync cursors (uidvalidity/uidnext/last_seen_uid/highest_modseq) | No |
| `mail_messages` | Synchronized message **METADATA ONLY** (headers/summary/flags/size); dedupe on `(folder_id, uidvalidity, uid)` | **No body/content, ever** |
| `draft_mirrors` | Draft→remote IMAP mapping; idempotent on `(draft_id, mailbox_id)` | No |
| `send_intents` | **Immutable** confirmed-send snapshot; unique `idempotency_key` | No (hashes only) |
| `send_attempts` | Outbound state machine w/ compare-and-set `version` | No |
| `transport_audit` | Content-free audit events (`event_type` + correlation/message ids + small non-content `detail`) | **No bodies** |

### transport (PRIVATE; no anon/authenticated access at all)

| Table | Purpose |
|-------|---------|
| `mailbox_credentials` | AEAD ciphertext/nonce/auth_tag/algorithm/key_version + AAD binding; **no plaintext column**; one active (non-revoked) credential per mailbox |
| `worker_claims` | Atomic per-`send_attempt` lease (worker_id, lease_until, heartbeat_at) for at-most-one-worker delivery |
| `worker_heartbeats` | Worker liveness (worker_id/last_seen/state); **no message content** |

## The worker-only decryption boundary

`mailbox_credentials` stores only the AEAD outputs. There is deliberately no
plaintext column and no SQL decrypt function. Decryption happens **outside the
database**, in the worker process that holds the KMS/data key; the DB only ever
sees ciphertext. The `aad` column records the additional-authenticated-data
contract (binding the ciphertext to its workspace + mailbox) so a credential
blob cannot be replayed against a different mailbox.

The browser has no route to this data: no schema USAGE, no grant, and the RPCs
that the browser can call never read or return credential material.

## Grant matrix (asserted in `transport_grant_matrix.test.sql`)

Roles: `anon`, `authenticated`, `service_role`, `transport_worker`.
Privileges checked: SELECT / INSERT / UPDATE / DELETE.

| Table (schema) | anon | authenticated | transport_worker | service_role |
|----------------|------|---------------|------------------|--------------|
| public.mailboxes | — | SELECT | SELECT | ALL |
| public.mailbox_folders | — | SELECT | SELECT,INSERT,UPDATE,DELETE | ALL |
| public.mail_messages | — | SELECT | SELECT,INSERT,UPDATE,DELETE | ALL |
| public.draft_mirrors | — | SELECT | SELECT,INSERT,UPDATE,DELETE | ALL |
| public.send_intents | — | SELECT | SELECT | ALL |
| public.send_attempts | — | SELECT | SELECT,UPDATE | ALL |
| public.transport_audit | — | SELECT | SELECT,INSERT | ALL |
| transport.mailbox_credentials | — | **none** | SELECT | ALL |
| transport.worker_claims | — | **none** | SELECT,INSERT,UPDATE,DELETE | ALL |
| transport.worker_heartbeats | — | **none** | SELECT,INSERT,UPDATE,DELETE | ALL |

Schema `transport`: `USAGE` granted to `transport_worker` + `service_role`
only; `anon`/`authenticated` have neither `USAGE` nor `CREATE`. Every grant uses
revoke-then-grant to defeat inherited / default-ACL privileges.

`transport_worker` is a system actor that operates across **all** workspaces, so
workspace-scoped RLS is meaningless for it; it is created `BYPASSRLS`. Its real
privilege boundary is the narrow, explicit table-grant set above — it never gets
broad public write (no access to drafts, workspaces, etc.), only the specific
transport tables it needs.

## RLS

Every `public` transport table has RLS enabled with a single SELECT policy
`using (public.is_workspace_member(workspace_id))`. There are intentionally
**no** INSERT/UPDATE/DELETE policies: the browser has no write grant, so the
only writers are the `SECURITY DEFINER` RPCs (which run as owner and bypass RLS)
and the `BYPASSRLS` worker. Cross-workspace isolation (a member of W1 sees zero
W2 rows) is proven in `transport_rls.test.sql`.

The three `transport` tables also have RLS enabled with **no** policies — belt
and suspenders. The only roles that can reach them are `BYPASSRLS`, and
`anon`/`authenticated` lack schema USAGE, so even a future mistaken table grant
would still expose zero rows to the browser.

## RPC authorization

Two `SECURITY DEFINER` RPCs (`search_path=''`, full qualification, null-uid
rejection, explicit `is_workspace_member` checks, EXECUTE revoked from
public/anon and granted to `authenticated` + `service_role`) — mirroring the
Phase 2 pattern exactly:

- **`create_send_intent(...)`** — the only write path for `send_intents`.
  Rejects a null `auth.uid()` (42501); validates arguments (22023); enforces
  membership + that the mailbox and draft both belong to the claimed workspace
  (P0002); refuses a disabled or kill-switched mailbox (55000). It
  **server-generates** the RFC 5322 `message_id` (from the sender domain), the
  `idempotency_key` (or honors a client-supplied one for safe retries), and the
  `confirmation_proof` — a SHA-256 over the canonical snapshot (payload +
  `confirmed_by` + `message_id` + `contract_version`) that binds the user's
  approval to the exact bytes to be sent. It inserts the immutable intent, seeds
  a `send_attempt` in state `confirmed`, and appends a content-free audit event,
  atomically. Idempotent on `idempotency_key`.
- **`request_mailbox_sync(mailbox_id, workspace_id)`** — validates membership +
  ownership + enabled/kill-switch, records a `mailbox_sync_requested` audit
  event, and returns. It performs **no IMAP in SQL**; the worker polls and does
  the actual sync/enqueue.

`send_intents` are frozen by a BEFORE UPDATE trigger (23514). There is
deliberately **no** DELETE trigger — that would abort legitimate FK
`ON DELETE CASCADE` from workspaces/mailboxes/drafts; browser deletion is
already impossible via the SELECT-only grant. `send_attempts` transitions are
validated by a trigger against an authoritative transition table
(`completed`/`needs_human_review`/`cancelled` terminal for the automated path),
which also forbids `version` rollback and workspace/intent mutation.
`transport_audit` is append-only, enforced purely by privileges (no writer can
UPDATE/DELETE it) so its `ON DELETE SET NULL`/`CASCADE` FKs stay free to run.

## Why credentials never reach the browser (summary)

1. They live in schema `transport`, which the browser role cannot access
   (`revoke all ... ; revoke usage`; no `USAGE` grant to `anon`/`authenticated`).
2. There is no plaintext column and no SQL decrypt path — the DB only stores
   AEAD ciphertext; decryption requires the worker's out-of-band key.
3. The RPCs the browser can call neither read nor return credential material.
4. Defense in depth: RLS is on with no policies even inside `transport`.

All four are covered by tests (`transport_grant_matrix.test.sql`,
`transport_rls.test.sql`).

## Production provisioning is a separate manual op

The migration creates `transport_worker` as **`NOLOGIN` with no password** —
there is no credential in version control. Production provisioning (assigning a
login secret / rotating the KMS data key / seeding real
`transport.mailbox_credentials`) is a deliberate out-of-band manual operation,
not part of this or any migration. Nothing here is applied to production;
transport remains disabled until the lead integrates and a separate, reviewed
deployment enables it.

## Test coverage

- `transport_grant_matrix.test.sql` — 178 assertions: full 4-role × 10-table ×
  4-privilege matrix, schema USAGE/CREATE, RPC EXECUTE matrix, and
  SECURITY DEFINER + pinned `search_path` on both RPCs.
- `transport_rls.test.sql` — 34 assertions: happy-path `create_send_intent`
  (server-generated message_id/proof/idempotency, seeded attempt + audit,
  idempotent replay), cross-workspace isolation, direct-write denial (42501),
  zero visibility into `transport.mailbox_credentials`, `send_intents` UPDATE
  immutability (23514), `send_attempts` legal/illegal transitions + version
  rollback (23514) + terminal state, non-member P0002, anon denial, kill-switch
  (55000), and FK-cascade cleanup not blocked by the immutability triggers.

The runner `scripts/test-db.sh` applies the full chain (baseline → Phase 2 ×2 →
Phase 3), re-applies each migration to prove idempotency, runs all suites, and
keeps the Phase 2 three-path equivalence check intact.
