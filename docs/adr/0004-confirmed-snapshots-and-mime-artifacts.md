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
inputs only) rejects any call whose `contract_version` is not exactly `2`
(`22023`) and stamps a **server-authoritative** `contract_version = 2` /
`proof_version = 2` (never the caller's value). In one transaction it locks the
draft (`FOR UPDATE`), requires the **exact** current revision (`P0409` on
mismatch, matching the `save_draft` convention), reuses-or-creates an immutable
`public.draft_versions` snapshot (`reason = 'send_confirmation'`) of the
confirmed subject/body, and binds the intent to it via a **composite-identity**
foreign key — `send_intents (draft_version_id, workspace_id, draft_id,
draft_revision)` → `draft_versions (id, workspace_id, draft_id,
source_revision)`, **`DEFERRABLE INITIALLY DEFERRED`, `ON DELETE NO ACTION`**
(not a single-column `draft_version_id` reference, and not `ON DELETE
RESTRICT`). The composite key makes the snapshot's own workspace/draft/revision
provably identical to the intent's; `MATCH SIMPLE` leaves a legacy NULL
`draft_version_id` un-enforced. The v2 confirmation-proof canonical additionally
covers `proof_version` and the exact `draft_version_id`, so the user's approval
is cryptographically bound to the exact snapshot that will be sent. A CHECK
constraint keeps `(proof_version, contract_version, draft_version_id)` moving
together (legacy `1/1/NULL` or current `2/2/NOT NULL`). A rejected confirm
(stale revision, sender mismatch, cross-workspace draft) writes no intent, no
attempt, no audit row **and no snapshot**.

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

- **Creation path**: the worker has **NO direct INSERT** on
  `send_mime_artifacts`; it creates artifacts **exclusively** through
  `transport.create_or_verify_send_mime_artifact` (SECURITY DEFINER; EXECUTE for
  `transport_worker` + `service_role` only). That function locks the attempt row
  `FOR UPDATE`, first-creates only while the attempt is exactly `claimed`, and on
  a re-call **VERIFIES** identity. The verify path **always re-hashes the
  caller's actual `p_raw_mime` against the stored durable `mime_sha256` /
  `size_bytes` — cleared or not** (echoing the old declared hash/size is
  insufficient; a cleared row keeps its digest/size, so a caller must still prove
  it holds the exact bytes), never overwrites retained bytes, and raises a
  uniform, content-free `23514` on any divergence.
- **Insert verification** (BEFORE INSERT trigger, `23514` on violation, fires on
  every insert path including a direct privileged INSERT): `raw_mime` NOT NULL
  with `sha256(raw_mime) = mime_sha256` and byte length `= size_bytes`; the
  attempt must belong to the intent; the intent's `workspace_id` and
  `message_id` must match the row; and the attempt must be exactly `claimed`. One
  artifact per attempt (unique; a duplicate is `23505`).
- **Artifact-before-SMTP guard** (BEFORE UPDATE OF state on
  `public.send_attempts`, `WHEN old.state='claimed' AND
new.state='smtp_in_progress'`, `23514` on violation): the transition is refused
  unless exactly one fully-valid **retained** artifact exists for the attempt
  (same intent/workspace/message_id; bytes present, not cleared; within 25 MiB;
  `octet_length(raw_mime)=size_bytes`; `sha256(raw_mime)=mime_sha256`, re-verified
  at this one-time boundary). This closes the ordering gap where an attempt could
  enter `smtp_in_progress` with no artifact — after which creation (`claimed`
  only) is permanently impossible. The guard does not fire on the other
  off-`claimed` transitions (`failed_before_delivery`/`cancelled`/
  `needs_human_review`).
- **Immutability**: the only legal UPDATE is the retention-clearing transition
  — `raw_mime` NOT NULL → NULL together with `cleared_at` NULL → NOT NULL, all
  other columns byte-identical — and only once the attempt is
  `completed`/`failed_before_delivery`/`cancelled`. Everything else is `23514`.
- **Retention**: `mime_sha256`, `size_bytes` and `message_id` survive clearing,
  so the proof outlives the bytes. Payloads are bounded at **25 MiB**
  (`rawMimeMaxBytes = 26214400`).
- **Browser denial**: anon/authenticated have zero reach (no schema USAGE, no
  table privilege). The worker gets exactly **SELECT + UPDATE** — **never INSERT,
  never DELETE**; only `service_role`'s operational ownership (or a full
  workspace/draft graph deletion via the parent CASCADE FKs) removes rows.

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
- Proven by `supabase/tests/database/confirmed_send_snapshots.test.sql` (87
  assertions) and `send_mime_artifacts.test.sql` (83 assertions) against the
  real roles, with no test-only grants.
