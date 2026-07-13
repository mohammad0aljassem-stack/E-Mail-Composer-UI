# ADR 0003: Canonical transport contract manifest (Phase 3A)

- Status: Accepted
- Date: 2026-07-13
- Scope: Phase 3A (transport foundation, contract hardening, worker transition grant)
- Builds on: ADR 0002 (draft lifecycle)

## Context

Phase 3A introduces the outbound transport contract: a least-privilege system
role (`transport_worker`), a private `transport` schema, and a state machine on
`public.send_attempts` guarded by a `SECURITY INVOKER` trigger that calls the
transition-table validator `public.phase3_send_attempt_transition_ok(text,text)`.
Three immutable, already-merged migrations define it:

1. `20260713100000_transport_foundation.sql`
2. `20260714100000_transport_contract_hardening.sql`
3. `20260715100000_worker_transition_grant.sql`

The exact privilege boundaries of that contract (which role may execute the
validator, which tables the worker may touch, which schema stays private) are
security-load-bearing and are consumed by more than one repository: this UI repo
owns and ships the migrations; a separate backend repo drives the worker against
them. Before this ADR those facts lived only as prose and as literals scattered
across shell and test code, which drifts.

## Decision

### The manifest is the single source of truth

`supabase/contracts/phase3-transport-contract.json` is the canonical, strict-JSON
declaration of the Phase 3 transport contract: the ordered migration set with
their locked `sha256` checksums, the worker role, the required/forbidden function
and table privileges, the protected private schemas, the queue facts, and the
fail-closed feature-flag default. It contains **no** UI commit SHA, **no** secret,
and **no** production identifier. Everything that needs these facts reads them
from this one file rather than re-hardcoding them.

### Immutable-checksum rule

Merged migrations are never edited, renamed, or renumbered. The manifest records
each migration's on-disk `sha256`. `scripts/verify-contract-manifest.mjs`
(run via `pnpm contract:verify`, in `scripts/test-db.sh`, and as a dedicated CI
step before the database tests) recomputes each checksum and **fails closed** on
any mismatch. The validator never auto-updates a recorded checksum: a changed
checksum is treated as an unreviewed mutation of an immutable migration and must
be resolved by explicit human review, not by rewriting the manifest to match. The
validator also fails if any migration with version >= `20260713100000` exists on
disk but is missing from the manifest, so a new Phase 3 migration cannot be added
without being declared.

The loaded migration chain is additionally proven against the manifest's declared
privilege matrix by `supabase/tests/database/contract_manifest_privileges.test.sql`
using the real roles — no test-only grant is injected.

### Cross-repo update workflow

A change to the transport contract flows in strictly ordered, separately reviewed
steps; no step below authorizes any production deployment:

1. In the **UI repo**, add a new **additive** migration (never edit a merged one)
   and update `supabase/contracts/phase3-transport-contract.json` in the **same
   PR** — new migration entry, its checksum, and any changed privilege facts.
2. Run the UI gates (`pnpm contract:verify`, `pnpm test:db`, the generated-types
   drift gate, lint/typecheck/test/build). Merge only when green.
3. The **backend repo** updates its lock in a **separate PR**, pinned to the exact
   merged UI commit SHA and the manifest checksum, verifies against it, and merges.
   The UI-SHA pin lives in the backend lock, never in this manifest.
4. Neither merge deploys anything. Production rollout is a distinct, separately
   authorized action gated behind the (default-disabled) transport feature flag.

## Consequences

- One reviewed edit point for the contract; drift between repos and between
  shell/test literals is eliminated.
- Tampering with a merged migration is caught by a fast static gate locally and in
  CI, before any database is touched.
- Generated database types remain limited to the `public` schema; a JSON manifest
  adds no types-visible object, so `database.types.ts` is unaffected.
