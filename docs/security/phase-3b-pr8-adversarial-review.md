# Phase 3B — PR #8 corrections: independent adversarial security review

**Reviewer role:** Independent adversarial reviewer (Agent 4). This reviewer did
NOT author the changes and wrote its own probes rather than trusting the
implementer's test suite.

**Branch reviewed:** `fix/phase-3b-snapshot-and-mime-contract`
**HEAD sha reviewed:** `1731f00f7bc40a1dbe7d8ae8950c7d4c71b0de10`
**Review date:** 2026-07-14

**Scope:** The two unmerged Phase 3B migrations
(`20260716100000_confirmed_send_snapshots.sql`,
`20260717100000_send_mime_artifacts.sql`) layered on the merged Phase 3A chain
(`20260713100000_transport_foundation.sql` … `20260715100000_worker_transition_grant.sql`),
plus the canonical contract manifest
(`supabase/contracts/phase3-transport-contract.json`). This round fixed two new
gaps that were independently confirmed closed: (1) the artifact-before-SMTP
ordering guard, and (2) always re-hashing the caller's bytes on the verify path,
including after retention clearing.

This document is content-free: it contains no raw MIME, message body, recipient
address, credential, secret, connection string, or production identifier — only
attack IDs, SQLSTATEs, role names, and ids-as-placeholders.

## Reproduction

Bring up a throwaway PostgreSQL 16 cluster (loads baseline + all 7 migrations on
port 54329 and prints DB_URL):

```
UI_REPO=/home/user/E-Mail-Composer-UI bash scripts/test-db.sh --keep
```

Independent probes were run as a single rolled-back transaction against the
resulting database using fresh, distinct fixture UUIDs (4444-prefixed workspaces,
users, mailboxes, drafts, intents) built with the real `create_draft` /
`create_send_intent` RPCs and the `set_config('request.jwt.claims', …)` +
`set local role` pattern. Roles exercised: `transport_worker`, `authenticated`,
`anon`, and a direct privileged (superuser) session. Tear down with:

```
bash scripts/test-db.sh --stop
```

Static checks (manifest + forbidden patterns) were run against the working tree:

```
node scripts/verify-contract-manifest.mjs
```

## Attack matrix — result per item

Every rejection was asserted by the observed SQLSTATE (and, where relevant, by
re-reading the row's state to confirm no side effect). "Blocked" = the attack was
refused with the expected SQLSTATE and left no illegitimate state change.

### NEW — artifact-before-SMTP guard (Correction 1)

| ID           | Probe intent                                                                                      | Expected block    | Observed                 | Result |
| ------------ | ------------------------------------------------------------------------------------------------- | ----------------- | ------------------------ | ------ |
| G1           | Attempt driven to `claimed` with NO MIME artifact; worker `UPDATE … state='smtp_in_progress'`     | 23514             | 23514                    | PASS   |
| G1b          | After G1, re-read the attempt state                                                               | stays `claimed`   | `claimed`                | PASS   |
| G2           | Create a valid retained artifact while `claimed`, then the same transition                        | succeeds          | `smtp_in_progress`       | PASS   |
| G3-fbd       | `claimed -> failed_before_delivery` with NO artifact (guard must not over-block)                  | succeeds          | `failed_before_delivery` | PASS   |
| G3-canc      | `claimed -> cancelled` with NO artifact                                                           | succeeds          | `cancelled`              | PASS   |
| G3-nhr       | `claimed -> needs_human_review` with NO artifact                                                  | succeeds          | `needs_human_review`     | PASS   |
| G4-invoker   | Guard function `require_mime_artifact_before_smtp` is SECURITY INVOKER                            | `prosecdef=false` | `false`                  | PASS   |
| G4-sp        | Guard function has `search_path=''`                                                               | empty             | `search_path=""`         | PASS   |
| G4-trig-when | Trigger is `BEFORE UPDATE OF state … WHEN (old.state='claimed' AND new.state='smtp_in_progress')` | matches           | matches                  | PASS   |
| G4msg        | Guard error message is content-free (no raw MIME / body / recipient)                              | clean             | clean                    | PASS   |

### NEW — always re-hash caller bytes on verify, incl. after clearing (Correction 2)

| ID      | Probe intent                                                                                                           | Expected block            | Observed                         | Result |
| ------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------- | -------------------------------- | ------ |
| V-setup | Create artifact while `claimed`, drive to `completed`, clear bytes (raw_mime→NULL)                                     | cleared                   | cleared                          | PASS   |
| V1      | Cleared row: verify with SAME refs + declared hash/size but DIFFERENT bytes (sha≠stored) — the load-bearing regression | 23514                     | 23514                            | PASS   |
| V2      | Cleared row: verify with the ORIGINAL bytes (sha=stored, size=stored)                                                  | returns the (cleared) row | returned same row, still cleared | PASS   |
| V3      | Cleared row: verify with `p_raw_mime = NULL`                                                                           | 23514                     | 23514                            | PASS   |
| V4      | Cleared row: verify with bytes of a different size than stored                                                         | 23514                     | 23514                            | PASS   |
| V5      | Non-cleared (retained) row: verify with divergent bytes + stale declared hash/size                                     | 23514                     | 23514                            | PASS   |

### Regression of the prior contract (independent spot-check)

| ID           | Probe intent                                                                                                                                                                                         | Expected block | Observed  | Result |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | --------- | ------ |
| R1           | `create_send_intent` with `p_contract_version = 1`                                                                                                                                                   | 22023          | 22023     | PASS   |
| R1b          | R1 leaves no `send_intents` row                                                                                                                                                                      | 0 rows         | 0         | PASS   |
| R2           | Confirm subject ≠ locked draft subject                                                                                                                                                               | P0409          | P0409     | PASS   |
| R3           | Composite identity FK rejects a mismatched (wrong-revision) snapshot reference; forced with `SET CONSTRAINTS ALL IMMEDIATE`                                                                          | 23503          | 23503     | PASS   |
| R4-legacy    | `get_send_snapshot` on a legacy (proof 1 / contract 1 / NULL snapshot) intent                                                                                                                        | uniform P0002  | P0002     | PASS   |
| R4-missing   | `get_send_snapshot` on a wholly missing intent (uniform, non-disclosing)                                                                                                                             | P0002          | P0002     | PASS   |
| R4-auth-exec | `authenticated` EXECUTE of `get_send_snapshot`                                                                                                                                                       | 42501          | 42501     | PASS   |
| R4-anon-exec | `anon` EXECUTE of `get_send_snapshot`                                                                                                                                                                | 42501          | 42501     | PASS   |
| R4-worker-dv | `transport_worker` direct SELECT on `public.draft_versions` (no worker table grant)                                                                                                                  | 42501          | 42501     | PASS   |
| R5-ins       | `transport_worker` direct INSERT on `send_mime_artifacts`                                                                                                                                            | 42501          | 42501     | PASS   |
| R5-del       | `transport_worker` direct DELETE on `send_mime_artifacts`                                                                                                                                            | 42501          | 42501     | PASS   |
| R5-browser   | `authenticated` SELECT on `send_mime_artifacts`                                                                                                                                                      | 42501          | 42501     | PASS   |
| R6           | First-create of an artifact while the attempt is in a non-`claimed` state (`confirmed`)                                                                                                              | 23514          | 23514     | PASS   |
| R7-before    | Retained artifacts exist before the workspace delete                                                                                                                                                 | >0             | true      | PASS   |
| R7-after     | Full workspace delete cascades artifacts to 0 rows                                                                                                                                                   | 0              | 0         | PASS   |
| R8           | `transport_worker` table privileges on `send_mime_artifacts` are exactly {SELECT, UPDATE} (INSERT / DELETE / TRUNCATE / REFERENCES / TRIGGER all denied)                                             | exact set      | exact set | PASS   |
| R9           | `get_send_snapshot`, `get_mirror_snapshot`, `create_or_verify_send_mime_artifact` are all `prosecdef=true` with `search_path=''`                                                                     | all true       | all true  | PASS   |
| R10          | Manifest checksums == on-disk for all 5 Phase 3 migrations (incl. migration B `25fb351e…`) and `transportContractVersion = 2`                                                                        | verify OK      | verify OK | PASS   |
| R11          | Grep both new migrations: no `rejectUnauthorized`, no production project ref, no `as any` (n/a for SQL), no raw-MIME/body/recipient logging (only column-name references in content-free error text) | none           | none      | PASS   |

## Notes on method

- G4-sp / R9 (`search_path=''`): PostgreSQL stores the setting in `pg_proc.proconfig`
  as the array element `search_path=""` (quoted empty string). All four transport
  functions (the guard plus the three grantable functions) carry it; confirmed
  directly against the catalog.
- R11: the strings `raw_mime` and `mime_sha256` appear only as column identifiers
  inside content-free `RAISE EXCEPTION` messages — no message, comment, or log
  statement ever emits actual bytes, body text, or recipient values.
- The contract manifest declares `featureFlagDefaults.MAIL_TRANSPORT_V1_ENABLED = false`;
  the transport path remains behind a disabled flag.

## Verdict

**SECURITY REVIEW PASSED — all listed attacks blocked** (2026-07-14).

Both new corrections are independently confirmed closed and the prior Phase 3B
contract holds under adversarial probing.
