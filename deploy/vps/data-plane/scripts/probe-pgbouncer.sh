#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
LC_ALL=C
export LC_ALL
unset PGPASSWORD PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGSERVICE PGSERVICEFILE
unset REDISCLI_AUTH COMPOSE_PROJECT_NAME COMPOSE_PROFILES

readonly EXPECTED_PROJECT=eventsales-prod
readonly EXPECTED_COMPOSE_FILE=deploy/vps/data-plane/compose.yaml
readonly DATABASE_NAME=event_sales_prod
readonly RUNTIME_ROLE=eventsales_runtime
readonly MIGRATOR_ROLE=eventsales_migrator
readonly PROOF_TABLE=public.eventsales_r44_pgbouncer_probe
readonly DDL_TABLE=public.eventsales_r44_runtime_ddl_probe
readonly DOCKER_TIMEOUT=20s
readonly CLIENT_TIMEOUT=12s

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DATA_PLANE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
REPOSITORY_ROOT=$(cd -- "$DATA_PLANE_DIR/../../.." && pwd -P)
COMPOSE_PROJECT=${COMPOSE_PROJECT:-$EXPECTED_PROJECT}
COMPOSE_FILE=${COMPOSE_FILE:-$EXPECTED_COMPOSE_FILE}
export COMPOSE_PROJECT COMPOSE_FILE

secret_dir=
migrator_secret=
runtime_client_secret=
evidence_file=
proof_object_may_exist=false
failure_reported=false
temporary_outputs=()
validated_secret_path=
created_output_path=
client_a_pid=

record() {
  if [[ -n "$evidence_file" ]]; then
    printf '%s\n' "$1" >>"$evidence_file"
  fi
}

report_preflight_failure() {
  local check_id=$1
  failure_reported=true
  record "PGBOUNCER_PREFLIGHT=FAIL"
  record "FAILED_CHECK=$check_id"
  printf 'STOP=PGBOUNCER_PROBE_PREFLIGHT_FAILED check=%s\n' "$check_id" >&2
  if [[ -n "$evidence_file" ]]; then
    printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
  fi
  exit 1
}

report_failure() {
  local check_id=$1
  failure_reported=true
  if [[ "$proof_object_may_exist" == true ]]; then
    record 'PGBOUNCER_STATE=FAILED_PRESERVED'
    record 'PGBOUNCER_PROBE=FAIL'
    record "FAILED_CHECK=$check_id"
    printf 'STOP=PGBOUNCER_PROBE_FAILED check=%s\n' "$check_id" >&2
    printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
    printf 'PROOF_OBJECT=%s\n' "$PROOF_TABLE" >&2
  else
    record 'PGBOUNCER_PREFLIGHT=FAIL'
    record "FAILED_CHECK=$check_id"
    printf 'STOP=PGBOUNCER_PROBE_PREFLIGHT_FAILED check=%s\n' "$check_id" >&2
    if [[ -n "$evidence_file" ]]; then
      printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
    fi
  fi
  exit 1
}

on_exit() {
  local status=$?
  trap - EXIT
  if ((status != 0)) && [[ "$failure_reported" != true ]]; then
    failure_reported=true
    if [[ "$proof_object_may_exist" == true ]]; then
      record 'PGBOUNCER_STATE=FAILED_PRESERVED'
      record 'PGBOUNCER_PROBE=FAIL'
      record 'FAILED_CHECK=UNEXPECTED_SHELL_FAILURE'
      printf 'STOP=PGBOUNCER_PROBE_FAILED check=UNEXPECTED_SHELL_FAILURE\n' >&2
      printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
      printf 'PROOF_OBJECT=%s\n' "$PROOF_TABLE" >&2
    else
      record 'PGBOUNCER_PREFLIGHT=FAIL'
      record 'FAILED_CHECK=UNEXPECTED_SHELL_FAILURE'
      printf 'STOP=PGBOUNCER_PROBE_PREFLIGHT_FAILED check=UNEXPECTED_SHELL_FAILURE\n' >&2
      if [[ -n "$evidence_file" ]]; then
        printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
      fi
    fi
  fi
  if [[ -n "$client_a_pid" ]] && kill -0 "$client_a_pid" 2>/dev/null; then
    kill "$client_a_pid" 2>/dev/null || true
    wait "$client_a_pid" 2>/dev/null || true
  fi
  local output_file
  for output_file in "${temporary_outputs[@]}"; do
    [[ -n "$output_file" ]] && rm -f -- "$output_file" 2>/dev/null || true
  done
}

trap on_exit EXIT
trap 'report_failure INTERRUPTED' HUP INT TERM

if (($# != 1)); then
  report_preflight_failure ARGUMENT_COUNT
fi
if ((EUID != 0)); then
  report_preflight_failure ROOT_REQUIRED
fi
if [[ "$COMPOSE_PROJECT" != "$EXPECTED_PROJECT" ]]; then
  report_preflight_failure COMPOSE_PROJECT_INVALID
fi
if [[ "$COMPOSE_FILE" != "$EXPECTED_COMPOSE_FILE" ]]; then
  report_preflight_failure COMPOSE_FILE_INVALID
fi

secret_dir=$1
if [[ "$secret_dir" != /* || "$secret_dir" == / || "$secret_dir" == */ || "$secret_dir" == *//* ]]; then
  report_preflight_failure SECRET_DIRECTORY_PATH_INVALID
fi

relative_path=${secret_dir#/}
IFS='/' read -r -a path_parts <<<"$relative_path"
current_path=
for part in "${path_parts[@]}"; do
  if [[ -z "$part" || "$part" == . || "$part" == .. ]]; then
    report_preflight_failure SECRET_DIRECTORY_PATH_INVALID
  fi
  current_path="${current_path%/}/$part"
  if [[ -L "$current_path" ]]; then
    report_preflight_failure SECRET_DIRECTORY_SYMLINK
  fi
done
if [[ ! -d "$secret_dir" ]]; then
  report_preflight_failure SECRET_DIRECTORY_NOT_DIRECTORY
fi
secret_metadata=$(stat -c '%u:%g:%a' -- "$secret_dir" 2>/dev/null) || report_preflight_failure SECRET_DIRECTORY_METADATA_UNAVAILABLE
if [[ "$secret_metadata" != 0:0:700 ]]; then
  report_preflight_failure SECRET_DIRECTORY_METADATA_MISMATCH
fi
resolved_secret_dir=$(cd -- "$secret_dir" && pwd -P 2>/dev/null) || report_preflight_failure SECRET_DIRECTORY_UNAVAILABLE
if [[ "$resolved_secret_dir" != "$secret_dir" ]]; then
  report_preflight_failure SECRET_DIRECTORY_PATH_NOT_CANONICAL
fi

validate_password_file() {
  local file_name=$1
  local path="$secret_dir/$file_name"
  local metadata size

  if [[ -L "$path" ]]; then
    report_preflight_failure "SECRET_FILE_SYMLINK_$file_name"
  fi
  if [[ ! -f "$path" ]]; then
    report_preflight_failure "SECRET_FILE_NOT_REGULAR_$file_name"
  fi
  metadata=$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null) || report_preflight_failure "SECRET_FILE_METADATA_UNAVAILABLE_$file_name"
  if [[ "$metadata" != 0:0:400 ]]; then
    report_preflight_failure "SECRET_FILE_METADATA_MISMATCH_$file_name"
  fi
  size=$(stat -c '%s' -- "$path" 2>/dev/null) || report_preflight_failure "SECRET_FILE_SIZE_UNAVAILABLE_$file_name"
  if [[ "$size" != 64 ]] || ! grep -Eq '^[0-9a-f]{64}$' "$path" 2>/dev/null; then
    report_preflight_failure "SECRET_FILE_FORMAT_INVALID_$file_name"
  fi
  validated_secret_path=$path
}

validate_password_file eventsales_migrator_password
migrator_secret=$validated_secret_path
validate_password_file eventsales_runtime_client_password
runtime_client_secret=$validated_secret_path
export EVENTSALES_SECRET_DIR="$secret_dir"
cd -- "$REPOSITORY_ROOT"

if [[ -L "$secret_dir/pgbouncer.ini" || ! -f "$secret_dir/pgbouncer.ini" ]]; then
  report_preflight_failure PGBOUNCER_CONFIG_FILE_UNAVAILABLE
fi
if ! python3 -I - "$secret_dir/pgbouncer.ini" >/dev/null 2>&1 <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
required = {
    "pool_mode": "transaction",
    "max_client_conn": "64",
    "default_pool_size": "12",
    "reserve_pool_size": "4",
    "max_db_connections": "16",
    "max_user_connections": "16",
    "max_prepared_statements": "200",
}
found = {}
section = ""
mapping_count = 0
mapping_ok = False

try:
    for raw_line in path.read_text(encoding="ascii").splitlines():
        line = raw_line.strip()
        if not line or line.startswith((";", "#")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        key, separator, value = line.partition("=")
        if not separator:
            continue
        key = key.strip().lower()
        value = value.strip()
        if section == "pgbouncer" and key in required:
            if key in found:
                raise ValueError
            found[key] = value
        if section == "databases" and key == "event_sales_prod":
            mapping_count += 1
            fields = value.split()
            if len(fields) != 5:
                raise ValueError
            mapping_ok = (
                fields[0] == "host=postgres"
                and fields[1] == "port=5432"
                and fields[2] == "dbname=event_sales_prod"
                and fields[3] == "user=eventsales_runtime"
                and re.fullmatch(r"password=[0-9a-f]{64}", fields[4]) is not None
            )
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)

if found != required or mapping_count != 1 or not mapping_ok:
    raise SystemExit(1)
PY
then
  report_preflight_failure PGBOUNCER_CONFIG_MISMATCH
fi

compose() {
  timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" "$@"
}

if ! command -v docker >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  report_preflight_failure REQUIRED_TOOL_UNAVAILABLE
fi
if ! compose config -q >/dev/null 2>&1; then
  report_preflight_failure COMPOSE_CONFIG_FAILED
fi
if ! model=$(compose config --format json 2>/dev/null); then
  report_preflight_failure COMPOSE_MODEL_UNAVAILABLE
fi
if ! printf '%s' "$model" | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("services",{}).get("pgbouncer",{}); raise SystemExit(1 if s.get("ports") else 0)' >/dev/null 2>&1; then
  report_preflight_failure PGBOUNCER_HOST_PORT_CONFIGURED
fi
unset model

running_services=$(compose ps --status running --services postgres pgbouncer 2>/dev/null) || report_preflight_failure COMPOSE_STATUS_FAILED
running_services=$(printf '%s\n' "$running_services" | sed '/^[[:space:]]*$/d' | sort)
if [[ "$running_services" != $'pgbouncer\npostgres' ]]; then
  report_preflight_failure PGBOUNCER_SERVICES_NOT_RUNNING
fi

inspect_unpublished_ports() {
  local service=$1
  local container_id ports_json

  container_id=$(compose ps -q "$service" 2>/dev/null) || report_preflight_failure "${service^^}_CONTAINER_LOOKUP_FAILED"
  if [[ ! "$container_id" =~ ^[[:xdigit:]]{12,64}$ ]]; then
    report_preflight_failure "${service^^}_CONTAINER_LOOKUP_FAILED"
  fi
  ports_json=$(timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" docker inspect --format '{{json .NetworkSettings.Ports}}' "$container_id" 2>/dev/null) || report_preflight_failure "${service^^}_PORT_INSPECT_FAILED"
  if ! python3 -c 'import json,sys; ports=json.loads(sys.argv[1]); raise SystemExit(1 if any(bool(v) for v in ports.values()) else 0)' "$ports_json" >/dev/null 2>&1; then
    report_preflight_failure "${service^^}_HOST_PORT_PUBLISHED"
  fi
}

inspect_unpublished_ports pgbouncer

evidence_file=$(mktemp -- "$secret_dir/eventsales-r44-pgbouncer.XXXXXXXX") || report_preflight_failure EVIDENCE_FILE_CREATE_FAILED
chmod 600 -- "$evidence_file" || report_preflight_failure EVIDENCE_FILE_PERMISSION_FAILED
record 'PGBOUNCER_STATE=PRISTINE'
record 'PGBOUNCER_CONFIG=PASS'

compose exec -T postgres sh -c 'command -v psql >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1' >/dev/null 2>&1 || report_preflight_failure POSTGRES_CLIENT_UNAVAILABLE

psql_with_secret() {
  local secret_file=$1
  local host=$2
  local port=$3
  local database=$4
  local username=$5
  local output_file=$6
  shift 6

  {
    cat -- "$secret_file"
    printf '\n'
  } | timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
      exec -T -i postgres sh -c '
        set -eu
        umask 077
        host=$1
        port=$2
        database=$3
        username=$4
        IFS= read -r credential || exit 90
        passfile=$(mktemp /tmp/eventsales-r44-pgpass.XXXXXXXX) || exit 91
        chmod 600 "$passfile" || exit 92
        trap '\''rm -f -- "$passfile"'\'' EXIT
        trap '\''exit 128'\'' HUP INT TERM
        printf "%s:%s:%s:%s:%s\n" "$1" "$2" "$3" "$4" "$credential" >"$passfile"
        unset credential
        shift 4
        export PGPASSFILE="$passfile"
        export PGCONNECT_TIMEOUT=5
        set +e
        timeout '"$CLIENT_TIMEOUT"' psql -X -w -h "$host" -p "$port" -U "$username" -d "$database" -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$@"
        status=$?
        exit "$status"
      ' sh "$host" "$port" "$database" "$username" "$@" >"$output_file" 2>&1
}

psql_with_secret_stdin() {
  local secret_file=$1
  local host=$2
  local port=$3
  local database=$4
  local username=$5
  local output_file=$6
  shift 6

  {
    cat -- "$secret_file"
    printf '\n'
    cat
  } | timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
      exec -T -i postgres sh -c '
        set -eu
        umask 077
        host=$1
        port=$2
        database=$3
        username=$4
        IFS= read -r credential || exit 90
        passfile=$(mktemp /tmp/eventsales-r44-pgpass.XXXXXXXX) || exit 91
        chmod 600 "$passfile" || exit 92
        trap '\''rm -f -- "$passfile"'\'' EXIT
        trap '\''exit 128'\'' HUP INT TERM
        printf "%s:%s:%s:%s:%s\n" "$1" "$2" "$3" "$4" "$credential" >"$passfile"
        unset credential
        shift 4
        export PGPASSFILE="$passfile"
        export PGCONNECT_TIMEOUT=5
        set +e
        timeout '"$CLIENT_TIMEOUT"' psql -X -w -h "$host" -p "$port" -U "$username" -d "$database" \
          -qAt -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$@"
        status=$?
        exit "$status"
      ' sh "$host" "$port" "$database" "$username" "$@" >"$output_file" 2>&1
}

create_output_file() {
  created_output_path=$(mktemp -- "$secret_dir/.eventsales-r44-pgbouncer-output.XXXXXXXX") || report_preflight_failure CLIENT_OUTPUT_CREATE_FAILED
  chmod 600 -- "$created_output_path" || report_preflight_failure CLIENT_OUTPUT_PERMISSION_FAILED
  temporary_outputs+=("$created_output_path")
}

assert_psql_sql() {
  local secret_file=$1 host=$2 port=$3 database=$4 username=$5 sql=$6 expected=$7 check_id=$8
  local output_file actual
  create_output_file
  output_file=$created_output_path
  if ! psql_with_secret "$secret_file" "$host" "$port" "$database" "$username" "$output_file" -qAt -c "$sql"; then
    report_failure "$check_id"
  fi
  actual=$(<"$output_file")
  if [[ "$actual" != "$expected" ]]; then
    report_failure "$check_id"
  fi
}

create_output_file
output_file=$created_output_path
if ! psql_with_secret "$migrator_secret" postgres 5432 "$DATABASE_NAME" "$MIGRATOR_ROLE" "$output_file" -qAt -c "SELECT to_regclass('$PROOF_TABLE') IS NULL"; then
  report_preflight_failure PGBOUNCER_PROOF_OBJECT_CHECK_FAILED
fi
if [[ "$(<"$output_file")" != t ]]; then
  failure_reported=true
  record 'PGBOUNCER_PROOF_OBJECT=ALREADY_EXISTS'
  printf 'STOP=PGBOUNCER_PROOF_OBJECT_ALREADY_EXISTS\n' >&2
  printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
  exit 1
fi

proof_object_may_exist=true
record 'PGBOUNCER_STATE=PROOF_OBJECT_CREATE_ATTEMPTED'
create_output_file
output_file=$created_output_path
if ! psql_with_secret "$migrator_secret" postgres 5432 "$DATABASE_NAME" "$MIGRATOR_ROLE" "$output_file" \
  -v ON_ERROR_STOP=1 -c "CREATE TABLE $PROOF_TABLE (probe_key text NOT NULL, probe_value text NOT NULL)"; then
  report_failure PROOF_OBJECT_CREATE
fi
record 'PGBOUNCER_STATE=PROOF_OBJECT_CREATED'
record "PGBOUNCER_PROOF_OBJECT=$PROOF_TABLE"

create_output_file
output_file=$created_output_path
if ! psql_with_secret "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$output_file" -qAt -c 'SELECT 1'; then
  report_failure RUNTIME_AUTH
fi
if [[ "$(<"$output_file")" != 1 ]]; then
  report_failure RUNTIME_AUTH
fi
record 'PGBOUNCER_STATE=AUTH_PROVEN'
record 'PGBOUNCER_RUNTIME_AUTH=PASS'
printf 'PGBOUNCER_RUNTIME_AUTH=PASS\n'

assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "SELECT current_user || '|' || current_database() || '|' || current_setting('port')" \
  "$RUNTIME_ROLE|$DATABASE_NAME|5432" SERVER_IDENTITY
record 'PGBOUNCER_SERVER_IDENTITY=PASS'
printf 'PGBOUNCER_SERVER_IDENTITY=PASS\n'

assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "INSERT INTO $PROOF_TABLE (probe_key, probe_value) VALUES ('r44-marker', 'inserted') RETURNING probe_key || '|' || probe_value" \
  'r44-marker|inserted' RUNTIME_INSERT
assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "SELECT probe_key || '|' || probe_value FROM $PROOF_TABLE WHERE probe_key = 'r44-marker'" \
  'r44-marker|inserted' RUNTIME_SELECT
assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "UPDATE $PROOF_TABLE SET probe_value = 'updated' WHERE probe_key = 'r44-marker' RETURNING probe_key || '|' || probe_value" \
  'r44-marker|updated' RUNTIME_UPDATE
assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "SELECT probe_key || '|' || probe_value FROM $PROOF_TABLE WHERE probe_key = 'r44-marker'" \
  'r44-marker|updated' RUNTIME_UPDATE_VALUE
assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "DELETE FROM $PROOF_TABLE WHERE probe_key = 'r44-marker' RETURNING probe_key" \
  'r44-marker' RUNTIME_DELETE
assert_psql_sql "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" \
  "SELECT count(*) FROM $PROOF_TABLE" '0' RUNTIME_DELETE_EMPTY
record 'PGBOUNCER_STATE=DML_PROVEN'
record 'PGBOUNCER_RUNTIME_DML=PASS'
printf 'PGBOUNCER_RUNTIME_DML=PASS\n'

create_output_file
output_file=$created_output_path
ddl_status=0
assert_psql_sql "$migrator_secret" postgres 5432 "$DATABASE_NAME" "$MIGRATOR_ROLE" \
  "SELECT to_regclass('$DDL_TABLE') IS NULL" t RUNTIME_DDL_OBJECT_PRECHECK
if psql_with_secret "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$output_file" \
  -qAt -c "CREATE TABLE $DDL_TABLE (probe_marker text)"; then
  report_failure RUNTIME_DDL_UNEXPECTEDLY_ALLOWED
else
  ddl_status=$?
fi
if ((ddl_status == 124 || ddl_status == 137)) || ! grep -Eq 'ERROR:[[:space:]]+42501:' "$output_file"; then
  report_failure RUNTIME_DDL_DENIAL_NOT_PROVEN
fi
assert_psql_sql "$migrator_secret" postgres 5432 "$DATABASE_NAME" "$MIGRATOR_ROLE" \
  "SELECT to_regclass('$DDL_TABLE') IS NULL" t RUNTIME_DDL_OBJECT_ABSENT
create_output_file
output_file=$created_output_path
ddl_status=0
if psql_with_secret "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$output_file" \
  -qAt -c "ALTER TABLE $PROOF_TABLE OWNER TO $RUNTIME_ROLE"; then
  report_failure RUNTIME_OBJECT_OWNERSHIP_UNEXPECTEDLY_ALLOWED
else
  ddl_status=$?
fi
if ((ddl_status == 124 || ddl_status == 137)) || ! grep -Eq 'ERROR:[[:space:]]+42501:' "$output_file"; then
  report_failure RUNTIME_OBJECT_OWNERSHIP_DENIAL_NOT_PROVEN
fi
assert_psql_sql "$migrator_secret" postgres 5432 "$DATABASE_NAME" "$MIGRATOR_ROLE" \
  "SELECT pg_get_userbyid(c.relowner) FROM pg_class AS c WHERE c.oid = '$PROOF_TABLE'::regclass" \
  "$MIGRATOR_ROLE" RUNTIME_OBJECT_OWNER_REMAINS_MIGRATOR
record 'PGBOUNCER_STATE=DDL_DENIAL_PROVEN'
record 'PGBOUNCER_RUNTIME_DDL_DENIAL=PASS'
printf 'PGBOUNCER_RUNTIME_DDL_DENIAL=PASS\n'

create_output_file
output_file=$created_output_path
direct_status=0
if psql_with_secret "$runtime_client_secret" postgres 5432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$output_file" -qAt -c 'SELECT 1'; then
  report_failure DIRECT_RUNTIME_CLIENT_PASSWORD_ACCEPTED
else
  direct_status=$?
fi
if ((direct_status == 124 || direct_status == 137)) || ! grep -Eq 'FATAL:[[:space:]]+28P01:' "$output_file"; then
  report_failure DIRECT_RUNTIME_CLIENT_AUTH_DENIAL_NOT_PROVEN
fi
record 'PGBOUNCER_STATE=DIRECT_CLIENT_AUTH_DENIAL_PROVEN'
record 'PGBOUNCER_DIRECT_CLIENT_AUTH_DENIAL=PASS'
printf 'PGBOUNCER_DIRECT_CLIENT_AUTH_DENIAL=PASS\n'

create_output_file
a_output=$created_output_path
create_output_file
b_output=$created_output_path
psql_with_secret_stdin "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$a_output" <<'PSQL' &
BEGIN;
SELECT pg_backend_pid();
COMMIT;
\! sleep 10
\q
PSQL
client_a_pid=$!
client_a_backend=
for ((attempt = 0; attempt < 50; attempt += 1)); do
  if grep -Eq '^[0-9]+$' "$a_output"; then
    client_a_backend=$(grep -E '^[0-9]+$' "$a_output" | head -n 1)
    break
  fi
  if ! kill -0 "$client_a_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [[ ! "$client_a_backend" =~ ^[0-9]+$ ]] || ! kill -0 "$client_a_pid" 2>/dev/null; then
  report_failure TRANSACTION_CLIENT_A_NOT_IDLE
fi
if ! psql_with_secret "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$b_output" \
  -qAt -c 'BEGIN; SELECT pg_backend_pid(); COMMIT;'; then
  report_failure TRANSACTION_CLIENT_B_QUERY
fi
client_b_backend=$(grep -E '^[0-9]+$' "$b_output" | head -n 1 || true)
if [[ ! "$client_b_backend" =~ ^[0-9]+$ ]] || [[ "$client_b_backend" != "$client_a_backend" ]]; then
  report_failure TRANSACTION_BACKEND_NOT_REUSED
fi
if ! wait "$client_a_pid"; then
  report_failure TRANSACTION_CLIENT_A_EXIT
fi
client_a_pid=
record 'PGBOUNCER_STATE=TRANSACTION_POOL_PROVEN'
record 'PGBOUNCER_TRANSACTION_POOL=PASS'
printf 'PGBOUNCER_TRANSACTION_POOL=PASS\n'

create_output_file
named_output=$created_output_path
create_output_file
named_script=$created_output_path
cat >"$named_script" <<'PSQL'
\set ON_ERROR_STOP on
SELECT $1::text || '-r44-bound' \parse eventsales_r44_named_statement
\bind_named eventsales_r44_named_statement 'eventsales-r44-input' \g
\close_prepared eventsales_r44_named_statement
PSQL
if ! psql_with_secret_stdin "$runtime_client_secret" pgbouncer 6432 "$DATABASE_NAME" "$RUNTIME_ROLE" "$named_output" \
  <"$named_script"; then
  report_failure NAMED_PREPARED_PROTOCOL
fi
if [[ "$(<"$named_output")" != 'eventsales-r44-input-r44-bound' ]]; then
  report_failure NAMED_PREPARED_RESULT
fi
record 'PGBOUNCER_STATE=NAMED_PREPARED_STATEMENT_PROVEN'
record 'PGBOUNCER_NAMED_PREPARED=PASS'
printf 'PGBOUNCER_NAMED_PREPARED=PASS\n'

record 'PGBOUNCER_STATE=PASS'
record 'PGBOUNCER_PROBE=PASS'
printf 'PGBOUNCER_CONFIG=PASS\n'
printf 'PGBOUNCER_PROBE=PASS\n'
