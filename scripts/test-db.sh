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
#   DB_URL=$(grep postgresql /tmp/db.txt | grep -oE 'postgresql://[^ ]+' | tail -1)
#   DB_URL="$DB_URL" bash scripts/gen-types.sh --check
set -euo pipefail

cd "$(dirname "$0")/.."

KEEP="${1:-}"
DATA_DIR="/tmp/pg-e-mail-composer-$$"
PORT=54329
PSQL_ARGS=(-U postgres -p "$PORT" -h localhost)

# Cleanup function (trap-safe)
cleanup() {
  if [[ "$KEEP" != "--keep" && -d "$DATA_DIR" ]]; then
    echo "Stopping PostgreSQL cluster..."
    pg_ctl -D "$DATA_DIR" stop -m fast 2>/dev/null || true
    rm -rf "$DATA_DIR"
  fi
}
trap cleanup EXIT

# Check if a PostgreSQL cluster is already running on this port
check_existing() {
  pg_isready -U postgres -p "$PORT" -h localhost >/dev/null 2>&1 || return 1
}

# Initialize a new PostgreSQL cluster
init_db() {
  echo "Initializing PostgreSQL 16 cluster at port $PORT..."
  mkdir -p "$DATA_DIR"
  initdb -D "$DATA_DIR" -A trust -U postgres >/dev/null 2>&1
}

# Start PostgreSQL server
start_db() {
  echo "Starting PostgreSQL server on port $PORT..."
  pg_ctl -D "$DATA_DIR" start -w -l "$DATA_DIR/pg.log" -o "-p $PORT" >/dev/null 2>&1
}

# Wait for PostgreSQL to be ready
wait_ready() {
  local attempts=0
  while ! pg_isready -U postgres -p "$PORT" -h localhost >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt 30 ]]; then
      echo "PostgreSQL failed to start after 30 attempts" >&2
      exit 1
    fi
    sleep 1
  done
}

# Create the application database if it doesn't exist
create_db() {
  psql "${PSQL_ARGS[@]}" -d postgres -c "CREATE DATABASE e_mail_composer;" 2>/dev/null || true
}

# Load the baseline schema and Phase 2 migration
load_schema() {
  local db="${PSQL_ARGS[@]}"

  echo "Loading baseline schema..."
  psql "${db[@]}" -d e_mail_composer \
    -v ON_ERROR_STOP=1 \
    -f supabase/baseline/production_schema_2026_07_11.sql >/dev/null

  echo "Applying Phase 2 migration..."
  psql "${db[@]}" -d e_mail_composer \
    -v ON_ERROR_STOP=1 \
    -f supabase/migrations/20260711130000_draft_lifecycle.sql >/dev/null
}

# Run SQL test suite
run_tests() {
  local test_file="$1"
  local test_name=$(basename "$test_file" .sql)

  echo "Running tests: $test_name"
  psql "${PSQL_ARGS[@]}" -d e_mail_composer \
    -v ON_ERROR_STOP=1 \
    -f "$test_file" 2>&1 | grep -E '^(NOTICE|WARNING|ERROR|FATAL)' || true
}

# Main execution
echo "Phase 2 Database Test Runner"
echo "============================"

if check_existing; then
  echo "Found existing PostgreSQL cluster on port $PORT, reusing..."
  # Still ensure our database exists
  create_db
else
  echo "No existing cluster found, starting fresh..."
  init_db
  start_db
  wait_ready
  create_db
fi

load_schema

# Run all SQL test files in order
test_dir="supabase/tests/database"
if [[ ! -d "$test_dir" ]]; then
  echo "ERROR: test directory not found: $test_dir" >&2
  exit 1
fi

test_count=0
for test_file in "$test_dir"/*.test.sql; do
  if [[ -f "$test_file" ]]; then
    run_tests "$test_file"
    test_count=$((test_count + 1))
  fi
done

if [[ $test_count -eq 0 ]]; then
  echo "WARNING: No test files found in $test_dir" >&2
fi

echo ""
echo "Database tests completed successfully."

if [[ "$KEEP" == "--keep" ]]; then
  DB_URL="postgresql://postgres@localhost:$PORT/e_mail_composer"
  echo ""
  echo "Database kept running (--keep flag):"
  echo "  DB_URL=$DB_URL"
  echo ""
  echo "To keep it alive in another terminal:"
  echo "  export DB_URL='$DB_URL'"
  echo ""
  echo "When done, kill it manually:"
  echo "  pkill -f 'postgres.*-p $PORT' || true"
  echo "  rm -rf $DATA_DIR"
fi
