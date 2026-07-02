#!/usr/bin/env bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v pg_dump >/dev/null 2>&1; then
  echo "backup_restore_proof: failed (pg_dump unavailable)"
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "backup_restore_proof: failed (psql unavailable)"
  exit 1
fi

source_db="${TEST_DATABASE_NAME:-event_sales_test}"
host="${TEST_DATABASE_HOST:-localhost}"
port="${TEST_DATABASE_PORT:-5432}"
username="${TEST_DATABASE_USERNAME:-postgres}"
password="${TEST_DATABASE_PASSWORD:-postgres}"
restore_db="${source_db}_backup_restore_proof"

export PGPASSWORD="$password"

cleanup() {
  dropdb -h "$host" -p "$port" -U "$username" --if-exists "$restore_db" >/dev/null 2>&1 || true
  rm -f /tmp/eventsales_backup_restore_proof.dump
}

trap cleanup EXIT

pg_dump -h "$host" -p "$port" -U "$username" -Fc "$source_db" -f /tmp/eventsales_backup_restore_proof.dump
createdb -h "$host" -p "$port" -U "$username" "$restore_db"
pg_restore -h "$host" -p "$port" -U "$username" -d "$restore_db" --no-owner --no-privileges /tmp/eventsales_backup_restore_proof.dump

if MIX_ENV=test \
  DATABASE_URL="ecto://${username}:${password}@${host}:${port}/${restore_db}" \
  mix ecto.migrate >/dev/null; then
  if psql -h "$host" -p "$port" -U "$username" -d "$restore_db" -Atqc "SELECT 1" | grep -q '^1$'; then
    echo "backup_restore_proof: passed"
    exit 0
  fi
fi

echo "backup_restore_proof: failed"
exit 1
