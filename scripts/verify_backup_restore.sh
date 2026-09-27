#!/usr/bin/env bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ -L .env.local ]]; then
  echo "backup_restore_proof: failed (.env.local must be a regular file)"
  exit 1
fi

if [[ -f .env.local ]]; then
  local_env_permissions="$(stat -c '%a' .env.local)"
  if [[ "${local_env_permissions}" != "600" ]]; then
    echo "backup_restore_proof: failed (.env.local permissions must be 600)"
    exit 1
  fi

  # shellcheck disable=SC1091
  set -a
  source .env.local
  set +a
fi

for tool in pg_dump psql pg_restore createdb dropdb mix; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "backup_restore_proof: failed (${tool} unavailable)"
    exit 1
  fi
done

test_base="${TEST_DATABASE_NAME:-event_sales_test}"
partition="${MIX_TEST_PARTITION:-}"
host="${TEST_DATABASE_HOST:-127.0.0.1}"
port="${TEST_DATABASE_PORT:-55433}"
username="${TEST_DATABASE_USERNAME:-eventsales_test}"
password="${TEST_DATABASE_PASSWORD:-}"
source_db="${test_base}${partition}"
restore_db_base="${test_base}_backup_restore_$(date -u +%Y%m%d%H%M%S)_$$"
restore_db="${restore_db_base}${partition}"
restore_db_created=false

if [[ "${host}" != "127.0.0.1" || "${port}" != "55433" ]]; then
  echo "backup_restore_proof: failed (must use PostgreSQL TEST at 127.0.0.1:55433)"
  exit 1
fi

if [[ "${username}" != "eventsales_test" || -z "${password}" ]]; then
  echo "backup_restore_proof: failed (non-superuser TEST credentials are required)"
  exit 1
fi

if [[ ! "${test_base}" =~ ^event_sales_test(_[a-z0-9_]+)*$ ||
  ! "${partition}" =~ ^[0-9]*$ || ${#restore_db} -gt 63 ]]; then
  echo "backup_restore_proof: failed (database name is outside the EventSales TEST namespace)"
  exit 1
fi

dump_file="$(mktemp /tmp/eventsales_backup_restore.XXXXXX.dump)"
export PGPASSWORD="${password}"

cleanup() {
  local status="$?"
  if [[ "${restore_db_created}" == "true" ]]; then
    if ! dropdb --host "${host}" --port "${port}" --username "${username}" "${restore_db}" >/dev/null 2>&1 &&
      [[ "${status}" -eq 0 ]]; then
      status=1
    fi
  fi
  rm -f "${dump_file}"
  exit "${status}"
}

trap cleanup EXIT

pg_dump --host "${host}" --port "${port}" --username "${username}" -Fc \
  "${source_db}" --file "${dump_file}"
createdb --host "${host}" --port "${port}" --username "${username}" "${restore_db}"
restore_db_created=true
pg_restore --host "${host}" --port "${port}" --username "${username}" \
  --dbname "${restore_db}" --no-owner --no-privileges "${dump_file}"

export TEST_DATABASE_HOST="${host}"
export TEST_DATABASE_PORT="${port}"
export TEST_DATABASE_USERNAME="${username}"
export TEST_DATABASE_PASSWORD="${password}"
if [[ -n "${partition}" ]]; then
  export MIX_TEST_PARTITION="${partition}"
else
  unset MIX_TEST_PARTITION || true
fi

if MIX_ENV=test TEST_DATABASE_NAME="${restore_db_base}" mix ecto.migrate >/dev/null; then
  if psql --host "${host}" --port "${port}" --username "${username}" \
    --dbname "${restore_db}" --tuples-only --no-align --command "SELECT 1" | grep -q '^1$'; then
    echo "backup_restore_proof: passed"
    exit 0
  fi
fi

echo "backup_restore_proof: failed"
exit 1
