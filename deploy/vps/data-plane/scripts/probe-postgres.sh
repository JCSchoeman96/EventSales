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

postgres_running=$(
  docker compose --project-name "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" ps --status running --services postgres 2>/dev/null || true
)
postgres_running=${postgres_running//$'\r'/}
postgres_running=${postgres_running//$'\n'/}
if [[ "$postgres_running" != postgres ]]; then
  probe_fail POSTGRES_SERVICE_NOT_RUNNING
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

  if [[ "$actual" == t || "$actual" == true || "$actual" == 1 ]]; then
    probe_fail "$check_id"
  fi
}

probe_database() {
  expect_true database_exists "$(query_scalar postgres "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DATABASE_NAME}');")"
  expect_eq database_owner "$(query_scalar postgres "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${DATABASE_NAME}';")" eventsales_migrator
  expect_false public_connect "$(query_scalar postgres "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'CONNECT');")"
  expect_false public_temp "$(query_scalar postgres "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'TEMPORARY');")"
  printf 'POSTGRES_PROBE_DATABASE=PASS\n'
}

probe_roles() {
  local role

  for role in "${ROLE_NAMES[@]}"; do
    expect_true "role_exists_${role}" "$(query_scalar postgres "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role}');")"
    expect_true "role_login_${role}" "$(query_scalar postgres "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_superuser_${role}" "$(query_scalar postgres "SELECT rolsuper FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_createdb_${role}" "$(query_scalar postgres "SELECT rolcreatedb FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_createrole_${role}" "$(query_scalar postgres "SELECT rolcreaterole FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_replication_${role}" "$(query_scalar postgres "SELECT rolreplication FROM pg_roles WHERE rolname = '${role}';")"
    expect_false "role_bypassrls_${role}" "$(query_scalar postgres "SELECT rolbypassrls FROM pg_roles WHERE rolname = '${role}';")"
    expect_eq "role_connlimit_${role}" "$(query_scalar postgres "SELECT rolconnlimit::text FROM pg_roles WHERE rolname = '${role}';")" "${ROLE_CONN_LIMITS[$role]}"
    expect_true "role_password_${role}" "$(query_scalar postgres "SELECT EXISTS (SELECT 1 FROM pg_authid WHERE rolname = '${role}' AND rolpassword IS NOT NULL);")"
  done

  printf 'POSTGRES_PROBE_ROLES=PASS\n'
}

probe_runtime_privileges() {
  expect_true runtime_connect "$(query_scalar prod "SELECT has_database_privilege('eventsales_runtime', '${DATABASE_NAME}', 'CONNECT');")"
  expect_true runtime_schema_usage "$(query_scalar prod "SELECT has_schema_privilege('eventsales_runtime', 'public', 'USAGE');")"
  expect_false runtime_db_create "$(query_scalar prod "SELECT has_database_privilege('eventsales_runtime', '${DATABASE_NAME}', 'CREATE');")"
  expect_false runtime_db_temp "$(query_scalar prod "SELECT has_database_privilege('eventsales_runtime', '${DATABASE_NAME}', 'TEMPORARY');")"
  expect_false runtime_schema_create "$(query_scalar prod "SELECT has_schema_privilege('eventsales_runtime', 'public', 'CREATE');")"
  expect_false runtime_db_owner "$(query_scalar prod "SELECT pg_catalog.pg_get_userbyid(datdba) = 'eventsales_runtime' FROM pg_database WHERE datname = '${DATABASE_NAME}';")"
  expect_false runtime_schema_owner "$(query_scalar prod "SELECT pg_catalog.pg_get_userbyid(nspowner) = 'eventsales_runtime' FROM pg_namespace WHERE nspname = 'public';")"

  expect_true runtime_default_table_dml "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_runtime'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'r'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
      GROUP BY d.oid
      HAVING COUNT(DISTINCT acl.privilege_type) = 4
    );
  ")"

  expect_true runtime_default_sequence "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_runtime'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'S'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type IN ('USAGE', 'SELECT', 'UPDATE')
      GROUP BY d.oid
      HAVING COUNT(DISTINCT acl.privilege_type) = 3
    );
  ")"

  expect_true runtime_default_function_execute "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_runtime'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'f'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type = 'EXECUTE'
    );
  ")"

  printf 'POSTGRES_PROBE_RUNTIME_PRIVILEGES=PASS\n'
}

probe_backup_privileges() {
  expect_true backup_connect "$(query_scalar prod "SELECT has_database_privilege('eventsales_backup', '${DATABASE_NAME}', 'CONNECT');")"
  expect_true backup_schema_usage "$(query_scalar prod "SELECT has_schema_privilege('eventsales_backup', 'public', 'USAGE');")"
  expect_true backup_default_table_select "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_backup'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'r'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type = 'SELECT'
    );
  ")"

  expect_false backup_insert "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_backup'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'r'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
    );
  ")"

  expect_false backup_db_create "$(query_scalar prod "SELECT has_database_privilege('eventsales_backup', '${DATABASE_NAME}', 'CREATE');")"
  expect_false backup_db_temp "$(query_scalar prod "SELECT has_database_privilege('eventsales_backup', '${DATABASE_NAME}', 'TEMPORARY');")"
  expect_false backup_schema_create "$(query_scalar prod "SELECT has_schema_privilege('eventsales_backup', 'public', 'CREATE');")"

  expect_false backup_default_function_execute "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'eventsales_backup'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'f'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type = 'EXECUTE'
    );
  ")"

  printf 'POSTGRES_PROBE_BACKUP_PRIVILEGES=PASS\n'
}

probe_public_privileges() {
  expect_false public_schema_create "$(query_scalar prod "SELECT has_schema_privilege('public', 'public', 'CREATE');")"
  expect_false public_database_connect "$(query_scalar prod "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'CONNECT');")"
  expect_false public_database_temp "$(query_scalar prod "SELECT has_database_privilege('public', '${DATABASE_NAME}', 'TEMPORARY');")"

  expect_false public_default_function_execute "$(query_scalar prod "
    SELECT EXISTS (
      SELECT 1
      FROM pg_default_acl d
      JOIN pg_roles grantor ON grantor.oid = d.defaclrole
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles grantee ON grantee.rolname = 'public'
      JOIN LATERAL aclexplode(d.defaclacl) AS acl ON true
      WHERE grantor.rolname = 'eventsales_migrator'
        AND n.nspname = 'public'
        AND d.defaclobjtype = 'f'
        AND acl.grantee = grantee.oid
        AND acl.privilege_type = 'EXECUTE'
        AND acl.is_grant
    );
  ")"

  printf 'POSTGRES_PROBE_PUBLIC_PRIVILEGES=PASS\n'
}

probe_default_privileges() {
  expect_eq default_acl_table_count "$(query_scalar prod "
    SELECT COUNT(*)::text
    FROM pg_default_acl d
    JOIN pg_roles grantor ON grantor.oid = d.defaclrole
    JOIN pg_namespace n ON n.oid = d.defaclnamespace
    WHERE grantor.rolname = 'eventsales_migrator'
      AND n.nspname = 'public'
      AND d.defaclobjtype = 'r';
  ")" 3

  expect_eq default_acl_sequence_count "$(query_scalar prod "
    SELECT COUNT(*)::text
    FROM pg_default_acl d
    JOIN pg_roles grantor ON grantor.oid = d.defaclrole
    JOIN pg_namespace n ON n.oid = d.defaclnamespace
    WHERE grantor.rolname = 'eventsales_migrator'
      AND n.nspname = 'public'
      AND d.defaclobjtype = 'S';
  ")" 2

  expect_eq default_acl_function_count "$(query_scalar prod "
    SELECT COUNT(*)::text
    FROM pg_default_acl d
    JOIN pg_roles grantor ON grantor.oid = d.defaclrole
    JOIN pg_namespace n ON n.oid = d.defaclnamespace
    WHERE grantor.rolname = 'eventsales_migrator'
      AND n.nspname = 'public'
      AND d.defaclobjtype = 'f';
  ")" 2

  printf 'POSTGRES_PROBE_DEFAULT_PRIVILEGES=PASS\n'
}

probe_database
probe_roles
probe_runtime_privileges
probe_backup_privileges
probe_default_privileges
probe_public_privileges

printf 'POSTGRES_PROBE=PASS\n'
