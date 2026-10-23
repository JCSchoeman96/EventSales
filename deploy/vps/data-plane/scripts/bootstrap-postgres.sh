#!/bin/bash
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL

readonly COMPOSE_PROJECT=eventsales-prod
readonly DATABASE_NAME=event_sales_prod
readonly -a REQUIRED_SECRET_FILES=(
  eventsales_migrator_password
  eventsales_runtime_server_password
  eventsales_backup_password
)
readonly -a TARGET_ROLES=(
  eventsales_migrator
  eventsales_runtime
  eventsales_backup
)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DATA_PLANE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
COMPOSE_FILE="$DATA_PLANE_DIR/compose.yaml"
PROBE_SCRIPT="$SCRIPT_DIR/probe-postgres.sh"

stop_preflight() {
  printf 'STOP=%s\n' "$1" >&2
  exit 1
}

partial_failure() {
  printf 'STOP=POSTGRES_BOOTSTRAP_PARTIAL_FAILURE phase=%s\n' "$1" >&2
  exit 1
}

if (($# != 1)); then
  printf 'STOP=ARGUMENT_COUNT\n' >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'STOP=DOCKER_CLI_UNAVAILABLE\n' >&2
  exit 127
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  stop_preflight COMPOSE_FILE_MISSING
fi

if [[ ! -x "$PROBE_SCRIPT" ]]; then
  stop_preflight PROBE_SCRIPT_UNAVAILABLE
fi

secret_dir=$1
if [[ "$secret_dir" != /* || "$secret_dir" == / || "$secret_dir" == */ || "$secret_dir" == *//* ]]; then
  stop_preflight SECRET_DIRECTORY_PATH_NOT_CANONICAL_ABSOLUTE
fi

if [[ -L "$secret_dir" || ! -d "$secret_dir" ]]; then
  stop_preflight SECRET_DIRECTORY_INVALID
fi

validate_secret_file() {
  local name=$1
  local path="$secret_dir/$name"

  if [[ -L "$path" || ! -f "$path" ]]; then
    stop_preflight "SECRET_FILE_INVALID file=$name"
  fi

  local byte_count
  byte_count=$(stat -c '%s' -- "$path" 2>/dev/null) || stop_preflight "SECRET_SIZE_UNAVAILABLE file=$name"
  if [[ "$byte_count" != 64 ]] || ! LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$path" 2>/dev/null; then
    stop_preflight "SECRET_FORMAT_INVALID file=$name"
  fi
}

for name in "${REQUIRED_SECRET_FILES[@]}"; do
  validate_secret_file "$name"
done

postgres_running=$(
  docker compose --project-name "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" ps --status running --services postgres 2>/dev/null || true
)
postgres_running=${postgres_running//$'\r'/}
postgres_running=${postgres_running//$'\n'/}
if [[ "$postgres_running" != postgres ]]; then
  stop_preflight POSTGRES_SERVICE_NOT_RUNNING
fi

psql_admin() {
  docker compose --project-name "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" exec -T postgres \
    psql -X -w -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_prod() {
  docker compose --project-name "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" exec -T postgres \
    psql -X -w -U postgres -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 "$@"
}

query_scalar() {
  local sql=$1
  local result

  if ! result=$(psql_admin -tA -c "$sql" 2>/dev/null); then
    stop_preflight PSQL_QUERY_FAILED
  fi
  result=${result//$'\r'/}
  result=${result//$'\n'/}
  printf '%s' "$result"
}

printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_0_PREFLIGHT\n'

if [[ "$(query_scalar "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DATABASE_NAME}');")" == t ]]; then
  stop_preflight POSTGRES_BOOTSTRAP_TARGET_NOT_ABSENT
fi

for role in "${TARGET_ROLES[@]}"; do
  if [[ "$(query_scalar "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role}');")" == t ]]; then
    stop_preflight POSTGRES_BOOTSTRAP_TARGET_NOT_ABSENT
  fi
done

printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_1_ROLES\n'
if ! python3 - "$secret_dir/eventsales_migrator_password" "$secret_dir/eventsales_runtime_server_password" "$secret_dir/eventsales_backup_password" <<'PY' | psql_admin -f - >/dev/null
import re
import sys
from pathlib import Path

def read_password(path_text):
    path = Path(path_text)
    value = path.read_bytes()
    if len(value) != 64 or re.fullmatch(rb"[0-9a-f]{64}", value) is None:
        raise SystemExit(3)
    return value.decode("ascii")

try:
    migrator_password = read_password(sys.argv[1])
    runtime_password = read_password(sys.argv[2])
    backup_password = read_password(sys.argv[3])
except SystemExit:
    raise
except Exception:
    raise SystemExit(3)

roles = (
    ("eventsales_migrator", migrator_password, 2),
    ("eventsales_runtime", runtime_password, 20),
    ("eventsales_backup", backup_password, 2),
)

print("BEGIN;")
for name, password, conn_limit in roles:
    print(
        "CREATE ROLE {name} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
        "NOREPLICATION NOBYPASSRLS CONNECTION LIMIT {conn_limit} PASSWORD '{password}';".format(
            name=name,
            conn_limit=conn_limit,
            password=password,
        )
    )
print("COMMIT;")
PY
then
  partial_failure PHASE_1_ROLES
fi

printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_2_DATABASE\n'
if ! psql_admin -c "CREATE DATABASE ${DATABASE_NAME} OWNER eventsales_migrator;" >/dev/null 2>&1; then
  partial_failure PHASE_2_DATABASE
fi

printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_3_PRIVILEGES\n'
if ! psql_prod -f - >/dev/null 2>&1 <<'SQL'
BEGIN;

REVOKE ALL ON DATABASE event_sales_prod FROM PUBLIC;
REVOKE CONNECT, TEMPORARY ON DATABASE event_sales_prod FROM PUBLIC;
GRANT CONNECT ON DATABASE event_sales_prod TO eventsales_migrator;
GRANT CONNECT ON DATABASE event_sales_prod TO eventsales_runtime;
GRANT CONNECT ON DATABASE event_sales_prod TO eventsales_backup;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO eventsales_migrator;
GRANT ALL ON SCHEMA public TO eventsales_migrator;
GRANT USAGE ON SCHEMA public TO eventsales_runtime;
GRANT USAGE ON SCHEMA public TO eventsales_backup;

ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO eventsales_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  GRANT SELECT ON TABLES TO eventsales_backup;

ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO eventsales_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE eventsales_migrator IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO eventsales_runtime;

COMMIT;
SQL
then
  partial_failure PHASE_3_PRIVILEGES
fi

printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_4_PROBE\n'
probe_output_file=$(mktemp)
probe_status=0
if ! "$PROBE_SCRIPT" >"$probe_output_file" 2>&1; then
  probe_status=$?
fi
if ((probe_status != 0)) || ! grep -qx 'POSTGRES_PROBE=PASS' "$probe_output_file"; then
  rm -f -- "$probe_output_file"
  partial_failure PHASE_4_PROBE
fi
rm -f -- "$probe_output_file"

printf 'POSTGRES_BOOTSTRAP_STATE=BOOTSTRAPPED\n'
