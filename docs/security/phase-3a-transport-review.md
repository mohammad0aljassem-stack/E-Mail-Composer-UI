# Phase 3A security review — transport foundation

- Date: 2026-07-12
- Scope: Supabase-backed transport foundation (mailboxes, folder/message sync
  metadata, draft mirrors, confirmed send intents, outbound state machine,
  content-free audit) plus the private worker-only schema holding encrypted
  credentials and worker lease/heartbeat rows.
- Deliverable: two additive migrations applied after the Phase 2 chain
  (`20260711130000_draft_lifecycle` + `20260712100000_enforce_phase2_rpc_invariants`):
  1. `supabase/migrations/20260713100000_transport_foundation.sql` — the merged
     foundation (schema, tables, triggers, RPCs, worker role). **Unchanged**
     (sha256 `a2319ada…8c72a`).
  2. `supabase/migrations/20260714100000_transport_contract_hardening.sql` — a
     corrective, additive, idempotent hardening layer that CREATE-OR-REPLACEs the
     two RPCs, adds the durable `transport.sync_requests` table, adds the
     `send_intents.request_fingerprint` column, and re-asserts grants. It fixes
     three contract defects in the foundation (sender authority, durable sync
     requests, strict idempotency — see "Contract hardening" below).
- Production status: **still disabled.** Neither migration has been applied to
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

| Table             | Purpose                                                                                                        | Secrets?                  |
| ----------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------- |
| `mailboxes`       | Mailbox metadata + non-secret IMAP/SMTP host/port/security config, `enabled`, `kill_switch`                    | No passwords              |
| `mailbox_folders` | Discovered folders + safe-to-expose sync cursors (uidvalidity/uidnext/last_seen_uid/highest_modseq)            | No                        |
| `mail_messages`   | Synchronized message **METADATA ONLY** (headers/summary/flags/size); dedupe on `(folder_id, uidvalidity, uid)` | **No body/content, ever** |
| `draft_mirrors`   | Draft→remote IMAP mapping; idempotent on `(draft_id, mailbox_id)`                                              | No                        |
| `send_intents`    | **Immutable** confirmed-send snapshot; unique `idempotency_key`                                                | No (hashes only)          |
| `send_attempts`   | Outbound state machine w/ compare-and-set `version`                                                            | No                        |
| `transport_audit` | Content-free audit events (`event_type` + correlation/message ids + small non-content `detail`)                | **No bodies**             |

### transport (PRIVATE; no anon/authenticated access at all)

| Table                 | Purpose                                                                                                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mailbox_credentials` | AEAD ciphertext/nonce/auth_tag/algorithm/key_version + AAD binding; **no plaintext column**; one active (non-revoked) credential per mailbox           |
| `worker_claims`       | Atomic per-`send_attempt` lease (worker_id, lease_until, heartbeat_at) for at-most-one-worker delivery                                                 |
| `worker_heartbeats`   | Worker liveness (worker_id/last_seen/state); **no message content**                                                                                    |
| `sync_requests`       | Durable, claimable mailbox-sync requests (status pending→claimed→completed/failed); deduped per mailbox(+folder) while open; `last_error` content-free |

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

| Table (schema)                | anon | authenticated | transport_worker            | service_role |
| ----------------------------- | ---- | ------------- | --------------------------- | ------------ |
| public.mailboxes              | —    | SELECT        | SELECT                      | ALL          |
| public.mailbox_folders        | —    | SELECT        | SELECT,INSERT,UPDATE,DELETE | ALL          |
| public.mail_messages          | —    | SELECT        | SELECT,INSERT,UPDATE,DELETE | ALL          |
| public.draft_mirrors          | —    | SELECT        | SELECT,INSERT,UPDATE,DELETE | ALL          |
| public.send_intents           | —    | SELECT        | SELECT                      | ALL          |
| public.send_attempts          | —    | SELECT        | SELECT,UPDATE               | ALL          |
| public.transport_audit        | —    | SELECT        | SELECT,INSERT               | ALL          |
| transport.mailbox_credentials | —    | **none**      | SELECT                      | ALL          |
| transport.worker_claims       | —    | **none**      | SELECT,INSERT,UPDATE,DELETE | ALL          |
| transport.worker_heartbeats   | —    | **none**      | SELECT,INSERT,UPDATE,DELETE | ALL          |
| transport.sync_requests       | —    | **none**      | SELECT,UPDATE               | ALL          |

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
  **server-generates** the RFC 5322 `message_id` (from the **mailbox** domain — see
  sender authority below), honors/creates the `idempotency_key`, and the
  `confirmation_proof` — a SHA-256 over the canonical snapshot (payload +
  `confirmed_by` + `message_id` + `contract_version`) that binds the user's
  approval to the exact bytes to be sent. It inserts the immutable intent, seeds
  a `send_attempt` in state `confirmed`, and appends a content-free audit event,
  atomically. **Sender authority** and **strict idempotency** are enforced as
  described under "Contract hardening".
- **`request_mailbox_sync(mailbox_id, workspace_id)`** — validates membership +
  ownership + enabled/kill-switch, then **atomically** upserts a durable,
  claimable `transport.sync_requests` row (deduped per mailbox while an open
  request exists) **and** appends a content-free `mailbox_sync_requested` audit
  event in one transaction, returning the durable request id/status. It performs
  **no IMAP in SQL**; the worker claims the row and PR B enqueues/executes the
  sync. See "Contract hardening".

`send_intents` are frozen by a BEFORE UPDATE trigger (23514). There is
deliberately **no** DELETE trigger — that would abort legitimate FK
`ON DELETE CASCADE` from workspaces/mailboxes/drafts; browser deletion is
already impossible via the SELECT-only grant. `send_attempts` transitions are
validated by a trigger against an authoritative transition table
(`completed`/`needs_human_review`/`cancelled` terminal for the automated path),
which also forbids `version` rollback and workspace/intent mutation.
`transport_audit` is append-only, enforced purely by privileges (no writer can
UPDATE/DELETE it) so its `ON DELETE SET NULL`/`CASCADE` FKs stay free to run.

## Contract hardening (migration `20260714100000`)

The foundation shipped three contract defects. The additive hardening migration
CREATE-OR-REPLACEs the two RPCs and adds supporting objects to fix them. The
foundation file itself is untouched (sha256 `a2319ada…8c72a`).

### 1. Sender authority

**Defect.** The foundation trusted the client-supplied `p_sender` (only
format-validated) and built the `message_id` domain from it — a client could
stamp an intent (and the outgoing Message-ID) with an arbitrary sender/domain.

**Fix.** `public.mailboxes.email_address` is the authoritative sender (unique per
workspace, transport-owned). `create_send_intent` now:

- **Normalization (exact rule): `trim` then `lowercase`** — `lower(btrim(p_sender))`.
  The normalized value is format-validated (so a padded/mixed-case address is
  accepted and canonicalized).
- **Rejects** (errcode `22023`) any `p_sender` whose normalized form does not
  **exactly** equal the normalized mailbox address. Rejection happens before any
  write, so a rejected call leaves **no** intent / attempt / audit row.
- Derives the Message-ID domain from the **mailbox** address
  (`split_part(mailbox.email_address,'@',2)`), never from `p_sender`.
- **Stores the normalized authoritative sender** on the intent (`sender` column).

### 2. Durable, claimable mailbox-sync requests

**Defect.** `request_mailbox_sync` only appended an audit event and returned
`status:'requested'` — nothing durable for a worker to claim; a lost poll lost
the request.

**Fix.** A new **PRIVATE** table `transport.sync_requests` (id, workspace_id,
mailbox_id, `folder` nullable [NULL = whole mailbox], `status` ∈
{pending,claimed,completed,failed} CHECK, requested_by, requested_at, claimed_at,
completed_at, `attempt_count` default 0, `last_error` bounded + content-free). A
**partial-unique** index `uq_sync_requests_open` on
`(mailbox_id, coalesce(folder,''))` `WHERE status IN ('pending','claimed')`
guarantees at most one **open** request per mailbox(+folder).

`request_mailbox_sync` (CREATE OR REPLACE) now **atomically** upserts a pending
request — `INSERT … ON CONFLICT (mailbox_id, coalesce(folder,'')) WHERE status IN
('pending','claimed') DO UPDATE …` returns the **existing open row** if present,
else inserts a fresh one — **and** appends the content-free audit event, in one
transaction. It returns the durable `sync_request_id` + `status`. No pg-boss job
is created in SQL: this is the durable hand-off; **PR B** consumes the row and
enqueues. **Worker claim model:** `transport_worker` gets exactly `SELECT` +
`UPDATE` — it claims a `pending` row (sets `status='claimed'`, `claimed_at`),
drives it to `completed`/`failed`, and bumps `attempt_count` / sets a
content-free `last_error` on retry. The RPC runs `SECURITY DEFINER`, so it does
the `INSERT`; the worker needs no `INSERT`/`DELETE`. `anon`/`authenticated` get
**zero** (the schema is private; RLS is on with no policies as defence in depth).

### 3. Strict idempotency (P0409 on divergence)

**Defect.** On an existing `idempotency_key`, the foundation returned the stored
intent for **any** payload — a changed payload under a reused key silently got
the old intent.

**Fix.** `create_send_intent` computes a **deterministic fingerprint** —
`sha256` over a canonical `jsonb` of the request (workspace_id, mailbox_id,
draft_id, draft_revision, the **normalized authoritative sender**, recipients,
subject, html_hash, text_hash, attachment_manifest, template_version_id,
signature_id, contract_version), **excluding** server-generated fields
(`message_id`, `confirmation_proof`). It is persisted in the new nullable column
`public.send_intents.request_fingerprint` and populated on insert. On an
idempotency-key hit:

- non-member of the existing intent's workspace → uniform **P0002** (checked
  **first**, so existence never leaks — a non-member never sees P0409);
- member **and** the recomputed fingerprint **equals** the stored one → return
  the existing intent (safe replay);
- member **and** the fingerprint **differs** (any of the fields above changed) →
  **P0409**.

(A `NULL` stored fingerprint marks a legacy pre-hardening row and is returned
as-is; the table is new/empty in practice, so every real row carries a
fingerprint and divergence is caught strictly.)

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

- `transport_grant_matrix.test.sql` — 194 assertions: full 4-role × **11-table**
  × 4-privilege matrix (now including `transport.sync_requests`), schema
  USAGE/CREATE, RPC EXECUTE matrix, and SECURITY DEFINER + pinned `search_path`
  on both RPCs.
- `transport_rls.test.sql` — 35 assertions: happy-path `create_send_intent`
  (server-generated message_id/proof/idempotency, seeded attempt + audit,
  idempotent replay), cross-workspace isolation, direct-write denial (42501),
  zero visibility into `transport.mailbox_credentials`, `send_intents` UPDATE
  immutability (23514), `send_attempts` legal/illegal transitions + version
  rollback (23514) + terminal state, non-member P0002, anon denial, kill-switch
  (55000), durable `request_mailbox_sync` status, and FK-cascade cleanup not
  blocked by the immutability triggers.
- `transport_contract_hardening.test.sql` — 43 assertions covering the three
  corrected defects: **sender authority** (normalized match succeeds + stored
  normalized + mailbox-derived Message-ID domain; mismatch → 22023 with no
  intent/attempt/audit row); **strict idempotency** (identical replay returns the
  same intent; each kind of changed field — subject/recipients/draft_revision/
  html_hash/attachment_manifest/template_version_id/signature_id/contract_version/
  sender — → P0409; non-member reusing an existing key → uniform P0002, never
  P0409); **durable sync requests** (durable row + content-free audit; duplicate
  dedups to the same open row; cross-workspace non-member → P0002; the
  `transport.sync_requests` privilege matrix — anon/authenticated zero,
  transport_worker exactly SELECT+UPDATE, service_role ALL).

The runner `scripts/test-db.sh` applies the full chain (baseline → Phase 2 ×2 →
Phase 3 foundation ×2 → Phase 3 hardening ×2), re-applies each migration to prove
idempotency, runs all suites (**574 SQL assertions total**), and keeps the
Phase 2 three-path equivalence check intact.
