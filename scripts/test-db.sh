#!/usr/bin/env bash
# Phase 2 database + RLS test runner.
#
# Starts a throwaway PostgreSQL 16 cluster on port 54329 (or reuses an existing
# one if running), applies the baseline schema + Phase 2 migration, runs all
# SQL test suites, and exits non-zero if any test fails.
#
# Usage:
#   bash scripts/test-db.sh           # run tests and clean up
#   bash scripts/test-db.sh --keep    # run tests, leave DB running, print URL
#
# The --keep mode is used by CI to keep the database alive for type generation:
#   bash scripts/test-db.sh --keep > /tmp/db.txt
#   DB_URL=$(grep -oE 'postgresql://[^ ]+' /tmp/db.txt | tail -1)
#   DB_URL="$DB_URL" bash scripts/gen-types.sh --check
set -eu

cd "$(dirname "$0")/.."

KEEP="${1:-}"
DATA_DIR="${TEST_DB_DATA_DIR:-/tmp/pg-e-mail-composer}"
PORT="${TEST_DB_PORT:-54329}"
DB_NAME=e_mail_composer
PSQL_ARGS=(-U postgres -p "$PORT" -h localhost)

# Debian/Ubuntu apt packages install the server binaries (initdb, pg_ctl)
# under /usr/lib/postgresql/<ver>/bin, which is NOT on PATH — only client
# wrappers like psql are. Pick the newest version dir if initdb is missing.
if ! command -v initdb >/dev/null 2>&1; then
  PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -z "$PG_BIN" ]]; then
    echo "ERROR: initdb not found and no /usr/lib/postgresql/*/bin directory." >&2
    echo "Install PostgreSQL 16 server binaries (apt-get install postgresql-16)." >&2
    exit 1
  fi
  export PATH="$PG_BIN:$PATH"
fi

STARTED_CLUSTER=0

# initdb/postgres refuse to run as root (common in dev sandboxes). In that
# case run the cluster as the unprivileged postgres system user; clients
# still connect over localhost with trust auth, so psql as root is fine.
CLUSTER_USER=""
if [[ "$(id -u)" == "0" ]] && id postgres >/dev/null 2>&1; then
  CLUSTER_USER="postgres"
fi

run_cluster_cmd() {
  if [[ -n "$CLUSTER_USER" ]]; then
    su -s /bin/bash "$CLUSTER_USER" -c "PATH='$PATH' $1"
  else
    bash -c "$1"
  fi
}

cleanup() {
  if [[ "$KEEP" != "--keep" && "$STARTED_CLUSTER" == "1" && -d "$DATA_DIR" ]]; then
    run_cluster_cmd "pg_ctl -D '$DATA_DIR' stop -m fast" >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR"
  fi
}
trap cleanup EXIT

check_existing() {
  pg_isready -U postgres -p "$PORT" -h localhost >/dev/null 2>&1
}

init_db() {
  echo "Initializing PostgreSQL cluster (data dir $DATA_DIR, port $PORT)..."
  rm -rf "$DATA_DIR" "$DATA_DIR.initdb.log" "$DATA_DIR.pg.log"
  mkdir -p "$DATA_DIR"
  if [[ -n "$CLUSTER_USER" ]]; then
    chown "$CLUSTER_USER" "$DATA_DIR"
  fi
  # Logs live NEXT TO the data dir: initdb requires the data dir to be empty.
  if ! run_cluster_cmd "initdb -D '$DATA_DIR' -A trust -U postgres" > "$DATA_DIR.initdb.log" 2>&1; then
    echo "ERROR: initdb failed:" >&2
    tail -20 "$DATA_DIR.initdb.log" >&2 || true
    exit 1
  fi
}

start_db() {
  echo "Starting PostgreSQL server on port $PORT..."
  if [[ -n "$CLUSTER_USER" ]]; then
    touch "$DATA_DIR.pg.log" && chown "$CLUSTER_USER" "$DATA_DIR.pg.log"
  fi
  if ! run_cluster_cmd "pg_ctl -D '$DATA_DIR' start -w -t 60 -l '$DATA_DIR.pg.log' -o '-p $PORT -k /tmp -c listen_addresses=localhost'" >/dev/null 2>&1; then
    echo "ERROR: pg_ctl start failed:" >&2
    tail -30 "$DATA_DIR.pg.log" >&2 || true
    exit 1
  fi
  STARTED_CLUSTER=1
}

create_db() {
  # Recreate the DB so every run starts from a clean schema.
  psql "${PSQL_ARGS[@]}" -d postgres -q \
    -c "DROP DATABASE IF EXISTS $DB_NAME;" \
    -c "CREATE DATABASE $DB_NAME;"
}

apply_sql() {
  local label="$1" file="$2" out
  echo "$label ($file)..."
  if ! out="$(psql "${PSQL_ARGS[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -f "$file" 2>&1)"; then
    echo "ERROR: $label failed:" >&2
    printf '%s\n' "$out" | tail -40 >&2
    exit 1
  fi
}

run_test_suite() {
  local file="$1" out
  echo "Running tests: $(basename "$file")"
  if ! out="$(psql "${PSQL_ARGS[@]}" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f "$file" 2>&1)"; then
    printf '%s\n' "$out" | tail -60 >&2
    echo "FAIL: $file" >&2
    exit 1
  fi
  local passed
  passed="$(printf '%s\n' "$out" | grep -cE 'ok - ' || true)"
  echo "  $passed assertions passed"
}

echo "Phase 2 Database Test Runner"
echo "============================"

if check_existing; then
  echo "Reusing PostgreSQL cluster already running on port $PORT."
else
  init_db
  start_db
fi
create_db

apply_sql "Loading baseline schema" supabase/baseline/production_schema_2026_07_11.sql
apply_sql "Applying Phase 2 migration" supabase/migrations/20260711130000_draft_lifecycle.sql
# Idempotency: the migration must be safely re-runnable.
apply_sql "Re-applying Phase 2 migration (idempotency check)" supabase/migrations/20260711130000_draft_lifecycle.sql

test_dir="supabase/tests/database"
if [[ ! -d "$test_dir" ]]; then
  echo "ERROR: test directory not found: $test_dir" >&2
  exit 1
fi

test_count=0
for test_file in "$test_dir"/*.test.sql; do
  [[ -f "$test_file" ]] || continue
  run_test_suite "$test_file"
  test_count=$((test_count + 1))
done

if [[ $test_count -eq 0 ]]; then
  echo "ERROR: no test files found in $test_dir" >&2
  exit 1
fi

echo ""
echo "Database tests completed successfully ($test_count suite(s))."

if [[ "$KEEP" == "--keep" ]]; then
  echo ""
  echo "Database kept running (--keep):"
  echo "  DB_URL=postgresql://postgres@localhost:$PORT/$DB_NAME"
  echo ""
  echo "Stop it later with:"
  echo "  pg_ctl -D $DATA_DIR stop -m fast && rm -rf $DATA_DIR"
fi
