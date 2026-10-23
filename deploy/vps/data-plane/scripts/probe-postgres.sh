#!/bin/bash
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL

readonly COMPOSE_PROJECT=eventsales-prod
readonly DATABASE_NAME=event_sales_prod
readonly -a ROLE_NAMES=(
  eventsales_migrator
  eventsales_runtime
  eventsales_backup
)
readonly -A ROLE_CONN_LIMITS=(
  [eventsales_migrator]=2
  [eventsales_runtime]=20
  [eventsales_backup]=2
)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DATA_PLANE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
COMPOSE_FILE="$DATA_PLANE_DIR/compose.yaml"

probe_fail() {
  printf 'STOP=POSTGRES_PROBE_FAILED check=%s\n' "$1" >&2
  printf 'POSTGRES_PROBE=FAIL\n'
  exit 1
}

if (($# != 0)); then
  printf 'STOP=ARGUMENT_COUNT\n' >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'STOP=DOCKER_CLI_UNAVAILABLE\n' >&2
  exit 127
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  printf 'STOP=COMPOSE_FILE_MISSING\n' >&2
  exit 1
fi

validate_secret_directory_env() {
  local secret_dir=${EVENTSALES_SECRET_DIR:-}

  if [[ -z "$secret_dir" ]]; then
    probe_fail SECRET_DIRECTORY_ENV_INVALID
  fi
  if [[ "$secret_dir" != /* || "$secret_dir" == / || "$secret_dir" == */ || "$secret_dir" == *//* ]]; then
    probe_fail SECRET_DIRECTORY_ENV_INVALID
  fi

  local relative_path=${secret_dir#/}
  local part
  IFS='/' read -r -a path_parts <<<"$relative_path"
  for part in "${path_parts[@]}"; do
    if [[ -z "$part" || "$part" == . || "$part" == .. ]]; then
      probe_fail SECRET_DIRECTORY_ENV_INVALID
    fi
  done
}

validate_secret_directory_env

compose() {
  docker compose --project-name "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
}

ensure_compose_model() {
  if ! compose config -q >/dev/null 2>&1; then
    probe_fail COMPOSE_CONFIG_FAILED
  fi
}

ensure_postgres_service_running() {
  local postgres_running

  ensure_compose_model
  postgres_running=$(compose ps --status running --services postgres 2>/dev/null || true)
  postgres_running=${postgres_running//$'\r'/}
  postgres_running=${postgres_running//$'\n'/}
  if [[ "$postgres_running" != postgres ]]; then
    probe_fail POSTGRES_SERVICE_NOT_RUNNING
  fi
}

ensure_postgres_service_running

psql_admin() {
  compose exec -T postgres psql -X -w -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_prod() {
  compose exec -T postgres psql -X -w -U postgres -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 "$@"
}

query_scalar() {
  local database=$1
  local sql=$2
  local result

  if [[ "$database" == postgres ]]; then
    if ! result=$(psql_admin -tA -c "$sql" 2>/dev/null); then
      probe_fail PSQL_QUERY_FAILED
    fi
  else
    if ! result=$(psql_prod -tA -c "$sql" 2>/dev/null); then
      probe_fail PSQL_QUERY_FAILED
    fi
  fi

  result=${result//$'\r'/}
  if [[ "$result" == *$'\n'* ]]; then
    probe_fail PSQL_QUERY_MULTIPLE_ROWS
  fi
  result=${result//$'\n'/}
  printf '%s' "$result"
}

expect_eq() {
  local check_id=$1
  local actual=$2
  local expected=$3

  if [[ "$actual" != "$expected" ]]; then
    probe_fail "$check_id"
  fi
}

expect_true() {
  local check_id=$1
  local actual=$2

  if [[ "$actual" != t && "$actual" != true && "$actual" != 1 ]]; then
    probe_fail "$check_id"
  fi
}

expect_false() {
  local check_id=$1
  local actual=$2

  if [[ "$actual" != f && "$actual" != false && "$actual" != 0 ]]; then
    probe_fail "$check_id"
  fi
}

expect_exact_privilege_tuples() {
  local check_id=$1
  local grantee_role=$2
  local object_type=$3
  local expected_csv=$4
  local sql

  sql="
    WITH expected AS (
      SELECT privilege_type, false AS is_grantable
      FROM unnest(string_to_array('${expected_csv}', ',')) AS privilege_type
    ),
    actual AS (
      SELECT DISTINCT acl.privilege_type, acl.is_grantable
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = '${grantee_role}'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      JOIN pg_roles exploded_grantor ON exploded_grantor.oid = acl.grantor
      WHERE default_role.rolname = 'eventsales_migrator'
        AND exploded_grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = '${object_type}'
        AND acl.grantee = grantee.oid
    )
    SELECT
      NOT EXISTS (
        SELECT privilege_type, is_grantable FROM expected
        EXCEPT
        SELECT privilege_type, is_grantable FROM actual
      )
      AND NOT EXISTS (
        SELECT privilege_type, is_grantable FROM actual
        EXCEPT
        SELECT privilege_type, is_grantable FROM expected
      );
  "
  expect_true "$check_id" "$(query_scalar prod "$sql")"
}

expect_no_grant_option_on_role_defaults() {
  local check_id=$1
  local grantee_role=$2
  local object_type=$3
  local sql

  sql="
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = '${grantee_role}'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      JOIN pg_roles exploded_grantor ON exploded_grantor.oid = acl.grantor
      WHERE default_role.rolname = 'eventsales_migrator'
        AND exploded_grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = '${object_type}'
        AND acl.grantee = grantee.oid
        AND acl.is_grantable
    )::text;
  "
  expect_false "$check_id" "$(query_scalar prod "$sql")"
}

expect_no_unexpected_acl_grantor() {
  local check_id=$1
  local grantee_role=$2
  local object_type=$3
  local sql

  sql="
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = '${grantee_role}'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      LEFT JOIN pg_roles exploded_grantor ON exploded_grantor.oid = acl.grantor
      WHERE default_role.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = '${object_type}'
        AND acl.grantee = grantee.oid
        AND (exploded_grantor.rolname IS DISTINCT FROM 'eventsales_migrator')
    )::text;
  "
  expect_false "$check_id" "$(query_scalar prod "$sql")"
}

probe_database() {
  expect_true database_exists "$(query_scalar postgres "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DATABASE_NAME}');")"
  expect_eq database_owner "$(query_scalar postgres "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DATABASE_NAME}';")" eventsales_migrator
  expect_false public_connect "$(query_scalar postgres "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'CONNECT')::text;")"
  expect_false public_temp "$(query_scalar postgres "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'TEMPORARY')::text;")"
  printf 'POSTGRES_PROBE_DATABASE=PASS\n'
}

probe_roles() {
  local role

  for role in "${ROLE_NAMES[@]}"; do
    expect_true "role_exists_${role}" "$(query_scalar postgres "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role}');")"
    expect_true "role_login_${role}" "$(query_scalar postgres "SELECT rolcanlogin::text FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_superuser_${role}" "$(query_scalar postgres "SELECT rolsuper::text FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_createdb_${role}" "$(query_scalar postgres "SELECT rolcreatedb::text FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_createrole_${role}" "$(query_scalar postgres "SELECT rolcreaterole::text FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_replication_${role}" "$(query_scalar postgres "SELECT rolreplication::text FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_bypassrls_${role}" "$(query_scalar postgres "SELECT rolbypassrls::text FROM pg_roles WHERE rolname = '${role}';")"
    expect_eq "role_connlimit_${role}" "$(query_scalar postgres "SELECT rolconnlimit::text FROM pg_roles WHERE rolname = '${role}';")" "${ROLE_CONN_LIMITS[$role]}"
    expect_true "role_password_${role}" "$(query_scalar postgres "SELECT EXISTS (SELECT 1 FROM pg_authid WHERE rolname = '${role}' AND rolpassword IS NOT NULL);")"
  done

  printf 'POSTGRES_PROBE_ROLES=PASS\n'
}

probe_runtime_privileges() {
  expect_true runtime_connect "$(query_scalar prod "SELECT has_database_privilege('eventsales_runtime', '${DATABASE_NAME}', 'CONNECT');")"
  expect_true runtime_schema_usage "$(query_scalar prod "SELECT has_schema_privilege('eventsales_runtime', 'public', 'USAGE');")"
  expect_eq public_schema_owner "$(query_scalar prod "SELECT pg_catalog.pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public';")" eventsales_migrator
  expect_false runtime_db_create "$(query_scalar prod "SELECT has_database_privilege('eventsales_runtime', '${DATABASE_NAME}', 'CREATE')::text;")"
  expect_false runtime_db_temp "$(query_scalar prod "SELECT has_database_privilege('eventsales_runtime', '${DATABASE_NAME}', 'TEMPORARY')::text;")"
  expect_false runtime_schema_create "$(query_scalar prod "SELECT has_schema_privilege('eventsales_runtime', 'public', 'CREATE')::text;")"
  expect_false runtime_db_owner "$(query_scalar prod "SELECT (pg_catalog.pg_get_userbyid(datdba) = 'eventsales_runtime')::text FROM pg_database WHERE datname = '${DATABASE_NAME}';")"
  expect_false runtime_schema_owner "$(query_scalar prod "SELECT (pg_catalog.pg_get_userbyid(nspowner) = 'eventsales_runtime')::text FROM pg_namespace WHERE nspname = 'public';")"
  printf 'POSTGRES_PROBE_RUNTIME_PRIVILEGES=PASS\n'
}

probe_backup_privileges() {
  expect_true backup_connect "$(query_scalar prod "SELECT has_database_privilege('eventsales_backup', '${DATABASE_NAME}', 'CONNECT');")"
  expect_true backup_schema_usage "$(query_scalar prod "SELECT has_schema_privilege('eventsales_backup', 'public', 'USAGE');")"
  expect_false backup_db_create "$(query_scalar prod "SELECT has_database_privilege('eventsales_backup', '${DATABASE_NAME}', 'CREATE')::text;")"
  expect_false backup_db_temp "$(query_scalar prod "SELECT has_database_privilege('eventsales_backup', '${DATABASE_NAME}', 'TEMPORARY')::text;")"
  expect_false backup_schema_create "$(query_scalar prod "SELECT has_schema_privilege('eventsales_backup', 'public', 'CREATE')::text;")"
  printf 'POSTGRES_PROBE_BACKUP_PRIVILEGES=PASS\n'
}

probe_default_privileges() {
  expect_exact_privilege_tuples runtime_default_table_privileges eventsales_runtime r 'DELETE,INSERT,SELECT,UPDATE'
  expect_no_grant_option_on_role_defaults runtime_table_grant_option eventsales_runtime r
  expect_no_unexpected_acl_grantor runtime_table_acl_grantor eventsales_runtime r

  expect_exact_privilege_tuples runtime_default_sequence_privileges eventsales_runtime S 'SELECT,UPDATE,USAGE'
  expect_no_grant_option_on_role_defaults runtime_sequence_grant_option eventsales_runtime S
  expect_no_unexpected_acl_grantor runtime_sequence_acl_grantor eventsales_runtime S

  expect_exact_privilege_tuples runtime_default_function_privileges eventsales_runtime f EXECUTE
  expect_no_grant_option_on_role_defaults runtime_function_grant_option eventsales_runtime f
  expect_no_unexpected_acl_grantor runtime_function_acl_grantor eventsales_runtime f

  expect_exact_privilege_tuples backup_default_table_privileges eventsales_backup r SELECT
  expect_no_grant_option_on_role_defaults backup_table_grant_option eventsales_backup r
  expect_no_unexpected_acl_grantor backup_table_acl_grantor eventsales_backup r

  expect_false backup_default_sequence_privileges "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_backup'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      JOIN pg_roles exploded_grantor ON exploded_grantor.oid = acl.grantor
      WHERE default_role.rolname = 'eventsales_migrator'
        AND exploded_grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'S'
        AND acl.grantee = grantee.oid
    )::text;
  ")"

  expect_false backup_default_function_privileges "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_backup'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      JOIN pg_roles exploded_grantor ON exploded_grantor.oid = acl.grantor
      WHERE default_role.rolname = 'eventsales_migrator'
        AND exploded_grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'f'
        AND acl.grantee = grantee.oid
    )::text;
  ")"

  expect_true global_function_default_override_exists "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      WHERE default_role.rolname = 'eventsales_migrator'
        AND d.defaclnamespace = 0
        AND d.defaclobjtype = 'f'
    );
  ")"

  expect_false public_function_execute_in_global_default "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE default_role.rolname = 'eventsales_migrator'
        AND d.defaclnamespace = 0
        AND d.defaclobjtype = 'f'
        AND acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
    )::text;
  ")"

  expect_false public_default_table_any_grant "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE default_role.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'r'
        AND acl.grantee = 0
    )::text;
  ")"

  expect_false public_default_sequence_any_grant "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles default_role ON default_role.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE default_role.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'S'
        AND acl.grantee = 0
    )::text;
  ")"

  printf 'POSTGRES_PROBE_DEFAULT_PRIVILEGES=PASS\n'
}

probe_public_privileges() {
  expect_false public_schema_create "$(query_scalar prod "SELECT has_schema_privilege('public', 'public', 'CREATE')::text;")"
  expect_false public_database_connect "$(query_scalar prod "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'CONNECT')::text;")"
  expect_false public_database_temp "$(query_scalar prod "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'TEMPORARY')::text;")"
  printf 'POSTGRES_PROBE_PUBLIC_PRIVILEGES=PASS\n'
}

probe_database
probe_roles
probe_runtime_privileges
probe_backup_privileges
probe_default_privileges
probe_public_privileges

printf 'POSTGRES_PROBE=PASS\n'
