# ADR 0004: Confirmed send snapshots and private MIME artifacts (Phase 3B)

- Status: Accepted
- Date: 2026-07-13
- Scope: Phase 3B (confirmed send snapshots, exact MIME artifacts, transport contract v2)
- Builds on: ADR 0003 (canonical transport contract manifest)

## Context

A Phase 3A `send_intent` recorded only `draft_id + draft_revision` plus
client-supplied content hashes. The mutable `public.drafts` row can be edited
after confirmation, so neither the worker nor an auditor had a server-owned
copy of the exact content the user approved, and no durable proof of the exact
MIME bytes handed to SMTP existed at all. Two additive, idempotent migrations
close both gaps:

1. `20260716100000_confirmed_send_snapshots.sql`
2. `20260717100000_send_mime_artifacts.sql`

## Decision

### Confirm-time snapshot atomicity, exact reference, proof v2

`create_send_intent` (same signature; idempotency fingerprint unchanged —
inputs only) now, in one transaction: locks the draft (`FOR UPDATE`), requires
the **exact** current revision (`P0409` on mismatch, matching the `save_draft`
convention), reuses-or-creates an immutable `public.draft_versions` snapshot
(`reason = 'send_confirmation'`) of the confirmed subject/body, and binds the
intent to it via `send_intents.draft_version_id` (`ON DELETE RESTRICT`) with
`proof_version = 2`. The v2 confirmation-proof canonical additionally covers
`proof_version` and the exact `draft_version_id`, so the user's approval is
cryptographically bound to the exact snapshot that will be sent. A rejected
confirm (stale revision, sender mismatch, cross-workspace draft) writes no
intent, no attempt, no audit row **and no snapshot**.

### Private worker-only snapshot functions instead of a broad grant

The worker reads confirmed content **only** through two `SECURITY DEFINER`
functions in the private `transport` schema (empty `search_path`, fully
qualified, EXECUTE for `transport_worker` + `service_role` only):

- `transport.get_send_snapshot(uuid)` — exactly the snapshot referenced by an
  intent's `draft_version_id`, after asserting the snapshot's workspace/draft
  match the intent's (`P0002` on any miss or inconsistency).
- `transport.get_mirror_snapshot(uuid, uuid, bigint)` — the newest snapshot for
  one exact `(workspace, draft, source_revision)` triple (`P0002` on a miss).

`public.draft_versions` gets **no** table grant to `transport_worker` anywhere:
the accessors are the entire read surface, so the worker can never enumerate
draft history.

### Legacy intents are non-sendable fail-closed

Intents written before Phase 3B carry `proof_version = 1` and a `NULL`
`draft_version_id`. `transport.get_send_snapshot` raises `P0002` for them: under
the v2 worker contract they are **non-sendable fail-closed** — there is no
fallback to re-reading the mutable draft.

### The MIME artifact table contract

`transport.send_mime_artifacts` (private schema; RLS enabled with no policies,
like `mailbox_credentials`) stores the exact raw MIME bytes per `send_attempt`:

- **Insert verification** (BEFORE INSERT trigger, `23514` on violation):
  `raw_mime` NOT NULL with `sha256(raw_mime) = mime_sha256` and byte length
  `= size_bytes`; the attempt must belong to the claimed intent; the intent's
  `workspace_id` and `message_id` must match the row. One artifact per attempt
  (unique; a duplicate is `23505` — the worker repository's idempotent path is
  its `ON CONFLICT` insert).
- **Immutability**: the only legal UPDATE is the retention-clearing transition
  — `raw_mime` NOT NULL → NULL together with `cleared_at` NULL → NOT NULL, all
  other columns byte-identical — and only once the attempt is
  `completed`/`failed_before_delivery`/`cancelled`. Everything else is `23514`.
- **Retention**: `mime_sha256`, `size_bytes` and `message_id` survive clearing,
  so the proof outlives the bytes. Payloads are bounded at **25 MiB**
  (`rawMimeMaxBytes = 26214400`).
- **Browser denial**: anon/authenticated have zero reach (no schema USAGE, no
  table privilege). The worker gets exactly SELECT/INSERT/UPDATE — **never
  DELETE**; only `service_role`'s operational ownership can remove rows.

### Contract v2

`supabase/contracts/phase3-transport-contract.json` moves to
`transportContractVersion: 2` (`manifestSchemaVersion` stays 1): the two Phase 3B
migrations are listed with locked sha256 checksums, the snapshot accessors are
declared required-for-worker / forbidden-for-browser, the artifact table's
worker privileges (and forbidden DELETE) are declared, and the three invariants
(`sendIntentExactSnapshot`, `mimeArtifactImmutability`,
`mimeArtifactRetention`) are named so both repos test against the same words.
The ADR 0003 immutable-checksum rule and cross-repo workflow apply unchanged.

## Consequences

- Every new confirmation produces (or exactly reuses) an immutable snapshot;
  post-confirm draft edits can never change what is sent or what is audited.
- The worker contract (backend repo) must switch its send path to
  `transport.get_send_snapshot` and treat `P0002` as non-sendable; legacy
  proof-v1 intents require re-confirmation to become sendable.
- Sent-copy append and delivery disputes are resolvable byte-for-byte from
  `transport.send_mime_artifacts` while retention holds, and by hash after
  clearing.
- Proven by `supabase/tests/database/confirmed_send_snapshots.test.sql` (49
  assertions) and `send_mime_artifacts.test.sql` (42 assertions) against the
  real roles, with no test-only grants.
