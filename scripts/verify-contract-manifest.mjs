#!/usr/bin/env node
// ============================================================================
// Deterministic, static validator for the canonical Phase 3 transport
// contract manifest (supabase/contracts/phase3-transport-contract.json).
//
// This is a FILE/STATIC check only — it never touches a database, a network,
// or any production system. It parses the manifest with strict JSON.parse
// (never eval, never a dynamic require of untrusted content) and hashes the
// on-disk migration files with node:crypto. It exits non-zero with a clear
// message on any contract violation.
//
// It is the SINGLE implementation of the manifest check, used both locally
// (pnpm contract:verify / scripts/test-db.sh) and in CI.
//
// Load-bearing guarantees enforced here:
//   1. manifestSchemaVersion is present and supported (=== 1).
//   2. transportContractVersion is supported (=== 1).
//   3. Every listed migration file exists under supabase/migrations/.
//   4. Every listed migration's on-disk sha256 EXACTLY matches the manifest
//      value. A mismatch FAILS and demands review — the checksum is never
//      auto-updated (merged migrations are immutable).
//   5. Manifest migration order matches lexicographic filename order, orders
//      are 1..N contiguous, and no file is listed twice.
//   6. No Phase 3 transport migration on disk (version >= 20260713100000) is
//      absent from the manifest, and the three known Phase 3A migrations are
//      all listed.
// ============================================================================

import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST_PATH = join(
  REPO_ROOT,
  "supabase",
  "contracts",
  "phase3-transport-contract.json",
);
const MIGRATIONS_DIR = join(REPO_ROOT, "supabase", "migrations");

// Boundary version for the Phase 3 transport migration set. Any migration
// whose version prefix is >= this MUST be listed in the manifest.
const PHASE3_MIN_VERSION = 20260713100000n;
// The three known, immutable Phase 3A migrations that must always be listed.
const KNOWN_PHASE3_FILES = [
  "20260713100000_transport_foundation.sql",
  "20260714100000_transport_contract_hardening.sql",
  "20260715100000_worker_transition_grant.sql",
];
const SUPPORTED_MANIFEST_SCHEMA_VERSION = 1;
const SUPPORTED_TRANSPORT_CONTRACT_VERSION = 1;

const errors = [];
const fail = (msg) => errors.push(msg);

/** Return the leading numeric version of a migration filename, or null. */
function versionOf(file) {
  const m = /^(\d+)_/.exec(file);
  return m ? BigInt(m[1]) : null;
}

function sha256OfFile(absPath) {
  return createHash("sha256").update(readFileSync(absPath)).digest("hex");
}

// --- Parse the manifest (strict JSON, no eval) -----------------------------
let manifest;
try {
  manifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
} catch (err) {
  console.error(
    `contract:verify FAILED: cannot read/parse manifest at ${MANIFEST_PATH}: ${err.message}`,
  );
  process.exit(1);
}

// --- 1. manifestSchemaVersion ----------------------------------------------
if (manifest.manifestSchemaVersion !== SUPPORTED_MANIFEST_SCHEMA_VERSION) {
  fail(
    `manifestSchemaVersion must be ${SUPPORTED_MANIFEST_SCHEMA_VERSION} (got ${JSON.stringify(
      manifest.manifestSchemaVersion,
    )}).`,
  );
}

// --- 2. transportContractVersion -------------------------------------------
if (
  manifest.transportContractVersion !== SUPPORTED_TRANSPORT_CONTRACT_VERSION
) {
  fail(
    `transportContractVersion must be ${SUPPORTED_TRANSPORT_CONTRACT_VERSION} (got ${JSON.stringify(
      manifest.transportContractVersion,
    )}).`,
  );
}

// --- migrations array shape ------------------------------------------------
const migrations = manifest.migrations;
if (!Array.isArray(migrations) || migrations.length === 0) {
  fail("manifest.migrations must be a non-empty array.");
  // Nothing more we can check without a valid array.
  report();
}

const listedFiles = migrations.map((m) => m && m.file);

// --- 5a. no duplicate file entries -----------------------------------------
const seen = new Set();
for (const f of listedFiles) {
  if (typeof f !== "string" || f.length === 0) {
    fail(
      `every migration entry must have a string "file" (got ${JSON.stringify(f)}).`,
    );
    continue;
  }
  if (seen.has(f)) fail(`duplicate migration entry for "${f}".`);
  seen.add(f);
}

// --- 5b. orders are 1..N contiguous and match lexicographic filename order --
const orders = migrations.map((m) => m && m.order);
for (let i = 0; i < orders.length; i++) {
  if (orders[i] !== i + 1) {
    fail(
      `migration "order" values must be 1..N contiguous in array order; entry ${i} has order ${JSON.stringify(
        orders[i],
      )}, expected ${i + 1}.`,
    );
  }
}
const lexSorted = [...listedFiles].sort();
for (let i = 0; i < listedFiles.length; i++) {
  if (listedFiles[i] !== lexSorted[i]) {
    fail(
      "manifest migration order does not match lexicographic filename order: " +
        `array=[${listedFiles.join(", ")}] sorted=[${lexSorted.join(", ")}].`,
    );
    break;
  }
}

// --- 3 & 4. each listed migration exists on disk and its sha256 matches -----
for (const entry of migrations) {
  const file = entry && entry.file;
  if (typeof file !== "string" || file.length === 0) continue; // already reported
  const abs = join(MIGRATIONS_DIR, file);
  let actual;
  try {
    actual = sha256OfFile(abs);
  } catch {
    fail(
      `listed migration file is missing on disk: supabase/migrations/${file}.`,
    );
    continue;
  }
  const expected = entry.sha256;
  if (typeof expected !== "string" || !/^[0-9a-f]{64}$/.test(expected)) {
    fail(
      `migration "${file}" has a missing/invalid sha256 field in the manifest.`,
    );
    continue;
  }
  if (actual !== expected) {
    fail(
      `checksum MISMATCH for ${file}: manifest=${expected} on-disk=${actual}. ` +
        "Merged migrations are immutable — do NOT auto-update the manifest; this requires explicit review.",
    );
  }
}

// --- 6. no unlisted Phase 3 migration on disk ------------------------------
let onDisk = [];
try {
  onDisk = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql"));
} catch (err) {
  fail(`cannot read migrations directory ${MIGRATIONS_DIR}: ${err.message}`);
}
for (const file of onDisk) {
  const v = versionOf(file);
  if (v !== null && v >= PHASE3_MIN_VERSION && !seen.has(file)) {
    fail(
      `Phase 3 transport migration present on disk but NOT listed in the manifest: ${file} ` +
        `(version >= ${PHASE3_MIN_VERSION}). Every such migration must be listed.`,
    );
  }
}
// The three known Phase 3A migrations must always be listed.
for (const known of KNOWN_PHASE3_FILES) {
  if (!seen.has(known)) {
    fail(`required Phase 3A migration missing from the manifest: ${known}.`);
  }
}

report();

function report() {
  if (errors.length > 0) {
    console.error(
      "contract:verify FAILED — canonical transport contract manifest is invalid:",
    );
    for (const e of errors) console.error(`  - ${e}`);
    console.error(`\nManifest: ${MANIFEST_PATH}`);
    process.exit(1);
  }
  console.log(
    `contract:verify OK — manifest schema v${manifest.manifestSchemaVersion}, ` +
      `transport contract v${manifest.transportContractVersion}, ` +
      `${migrations.length} Phase 3 migration(s) verified (checksums match on-disk).`,
  );
  process.exit(0);
}
