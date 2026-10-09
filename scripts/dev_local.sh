#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly LOCAL_WORDPRESS_URL="http://localhost:10059"
readonly CATALOGUE_URL="${LOCAL_WORDPRESS_URL}/wp-json/eventsales/v1/tickera-catalog"
readonly PHOENIX_PID_FILE="${REPO_ROOT}/tmp/dev_local_phoenix.pid"

cd "${REPO_ROOT}"

log() {
  printf '[EventSales] %s\n' "$1"
}

problem() {
  printf 'Problem: %s\nWhy: %s\nFix: %s\n' "$1" "$2" "$3" >&2
  exit 1
}

usage() {
  printf 'Usage: bash scripts/dev_local.sh [start|status|stop|doctor|migrate|test|quality-pr|quality-ci|catalogue-dry-run]\n'
}

check_tools() {
  local tool

  for tool in elixir mix curl ss pg_isready psql python3 devcore-project; do
    command -v "${tool}" >/dev/null 2>&1 ||
      problem "${tool} is unavailable" "Local development requires ${tool}." "Install ${tool} and retry."
  done

}

mix_dev() {
  devcore-project run dev -- env -u MIX_TEST_PARTITION MIX_ENV=dev mix "$@"
}

mix_test() {
  devcore-project run test -- env -u MIX_TEST_PARTITION MIX_ENV=test \
    TEST_DATABASE_NAME="${TEST_DATABASE_NAME}" mix "$@"
}

mix_test_partition() {
  local partition="$1"
  shift

  devcore-project run test -- env MIX_TEST_PARTITION="${partition}" MIX_ENV=test \
    TEST_DATABASE_NAME="${TEST_DATABASE_NAME}" mix "$@"
}

configure_phoenix() {
  readonly PHOENIX_PORT="${PORT:-4001}"
  readonly PHOENIX_URL="${EVENTSALES_LOCAL_URL:-http://127.0.0.1:${PHOENIX_PORT}}"

  [[ "${PHOENIX_URL}" == "http://127.0.0.1:${PHOENIX_PORT}" ]] ||
    problem "EventSales local URL is invalid" "It must match the configured local Phoenix port." \
      "Set EVENTSALES_LOCAL_URL=http://127.0.0.1:${PHOENIX_PORT} in .env.local."
}

validate_local_env_file() {
  local env_file="${REPO_ROOT}/.env.local"

  [[ ! -L "${env_file}" ]] ||
    problem ".env.local must be a regular file" \
      "Local configuration cannot be a symlink because it could load the root .env." \
      "Replace .env.local with a regular file and set permissions to 600."

  [[ -f "${env_file}" ]] ||
    problem ".env.local is missing" "Local configuration must be a regular file." \
      "Copy .env.local.example to .env.local and set permissions to 600."

  local permissions
  permissions="$(stat -c '%a' "${env_file}")"
  [[ "${permissions}" == "600" ]] ||
    problem ".env.local permissions are ${permissions}" "Local configuration must be private." \
      "Run chmod 600 .env.local."
}

prepare_local_env() {
  local env_file="${REPO_ROOT}/.env.local"
  local example_file="${REPO_ROOT}/.env.local.example"

  [[ ! -L "${env_file}" ]] ||
    problem ".env.local must be a regular file" \
      "Local configuration cannot be a symlink because it could load the root .env." \
      "Replace .env.local with a regular file and set permissions to 600."

  [[ -f "${example_file}" ]] ||
      problem ".env.local.example is missing" "The local template is required." "Restore .env.local.example."

  if [[ ! -e "${env_file}" ]]; then
    cp "${example_file}" "${env_file}"
    chmod 600 "${env_file}"
    log "Created .env.local"
  else
    python3 - "${example_file}" "${env_file}" <<'PY'
from pathlib import Path
import os
import re
import tempfile
import sys

example = Path(sys.argv[1])
target = Path(sys.argv[2])
current = target.read_text()
keys = {
    match.group(1)
    for line in current.splitlines()
    if (match := re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=", line))
}
missing = []
for line in example.read_text().splitlines():
    match = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=", line)
    if match and match.group(1) not in keys:
        keys.add(match.group(1))
        missing.append(line)

if missing:
    text = current.rstrip() + "\n\n" + "\n".join(missing) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent, text=True)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
  fi
}

activate_devcore_project() {
  devcore-project plan
  devcore-project activate
}

load_local_env() {
  validate_local_env_file

  # shellcheck disable=SC1091
  set -a
  source "${REPO_ROOT}/.env.local"
  set +a
}

require_redis_url() {
  local name="$1"
  local value="$2"
  local port="$3"

  [[ "${value}" =~ ^redis://(.*@)?127\.0\.0\.1:${port}/[0-9]+$ ]] ||
    problem "${name} does not match its locked Redis target" \
      "${name} must use 127.0.0.1:${port}." \
      "Update ${name} in .env.local."
}

require_disabled() {
  local name="$1"
  local value="${!name:-}"

  [[ "${value}" == "false" ]] ||
    problem "${name} is not disabled" "Dangerous local side effects are blocked." "Set ${name}=false in .env.local."
}

validate_local_configuration() {
  [[ "${TICKERA_CATALOG_FEED_BASE_URL:-}" == "${LOCAL_WORDPRESS_URL}" ]] ||
    problem "catalogue base URL is not local" "Only ${LOCAL_WORDPRESS_URL} is allowed." \
      "Set TICKERA_CATALOG_FEED_BASE_URL=${LOCAL_WORDPRESS_URL} in .env.local."

  [[ "${EVENTSALES_DEV_DATABASE_USERNAME:-}" == "eventsales_dev" ]] ||
    problem "development database role is invalid" \
      "EventSales development must use eventsales_dev." \
      "Set EVENTSALES_DEV_DATABASE_USERNAME=eventsales_dev in .env.local."
  [[ -n "${EVENTSALES_DEV_DATABASE_PASSWORD:-}" ]] ||
    problem "development database password is missing" \
      "The workstation DEV role requires its local password." \
      "Set EVENTSALES_DEV_DATABASE_PASSWORD in .env.local."

  require_redis_url "REDIS_URL" "${REDIS_URL:-}" 56379
  require_redis_url "TEST_REDIS_URL" "${TEST_REDIS_URL:-}" 56380
  if [[ -n "${WEBHOOK_RATE_LIMIT_REDIS_URL:-}" ]]; then
    require_redis_url "WEBHOOK_RATE_LIMIT_REDIS_URL" "${WEBHOOK_RATE_LIMIT_REDIS_URL}" 56379
  fi

  require_disabled "CATALOG_AUTO_APPLY_HARD_ENABLED"
  require_disabled "WEBHOOK_REDIS_BUFFER_ENABLED"
  require_disabled "WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED"
  require_disabled "CATALOG_CHANGE_RECEIVER_ENABLED"
  require_disabled "CATALOG_CHANGE_DISPATCHER_ENABLED"
}

validate_test_configuration() {
  [[ "${TEST_DATABASE_USERNAME:-}" == "eventsales_test" ]] ||
    problem "test database role is invalid" \
      "EventSales tests must use eventsales_test." \
      "Set TEST_DATABASE_USERNAME=eventsales_test in .env.local."
  [[ -n "${TEST_DATABASE_PASSWORD:-}" ]] ||
    problem "test database password is missing" \
      "The workstation TEST role requires its local password." \
      "Set TEST_DATABASE_PASSWORD in .env.local."
  [[ "${TEST_DATABASE_HOST:-127.0.0.1}" == "127.0.0.1" ]] ||
    problem "test database host is invalid" \
      "EventSales tests must use the loopback TEST cluster." \
      "Set TEST_DATABASE_HOST=127.0.0.1 in .env.local."
  [[ "${TEST_DATABASE_PORT:-55433}" == "55433" ]] ||
    problem "test database port is invalid" \
      "EventSales tests must use PostgreSQL TEST on port 55433." \
      "Set TEST_DATABASE_PORT=55433 in .env.local."

  local test_database_name="${TEST_DATABASE_NAME:-event_sales_test}"
  [[ "${test_database_name}" =~ ^event_sales_test(_[a-z0-9_]+)*$ ]] ||
    problem "test database name is invalid" \
      "EventSales test databases must retain the event_sales_test prefix." \
      "Set TEST_DATABASE_NAME to event_sales_test or a project-owned test suffix."
}

check_secret_file() {
  [[ -n "${EVENTSALES_CATALOG_SECRET_FILE:-}" ]] ||
    problem "catalogue secret file is not configured" "EVENTSALES_CATALOG_SECRET_FILE is required." \
      "Set its local path in .env.local."
  [[ -f "${EVENTSALES_CATALOG_SECRET_FILE}" ]] ||
    problem "catalogue secret file is unavailable" "The configured path is not a regular file." \
      "Create the local secret file at the configured path."
}

load_catalogue_secret() {
  check_secret_file

  TICKERA_CATALOG_FEED_SECRET="$(
    < "${EVENTSALES_CATALOG_SECRET_FILE}"
  )"
  export TICKERA_CATALOG_FEED_SECRET

  [[ -n "${TICKERA_CATALOG_FEED_SECRET}" ]] ||
    problem "catalogue secret is empty" "Signed catalogue access requires a secret." \
      "Add the local catalogue secret to the configured file."
}

verify_wordpress() {
  curl --fail --silent --show-error --output /dev/null "${LOCAL_WORDPRESS_URL}" ||
    problem "local WordPress is unavailable" "${LOCAL_WORDPRESS_URL} did not respond successfully." \
      "Start local WordPress and retry."

  local catalogue_status
  catalogue_status="$(
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' "${CATALOGUE_URL}"
  )"

  [[ "${catalogue_status}" == "401" ]] ||
    problem "protected catalogue endpoint is unavailable" "Unsigned request returned HTTP ${catalogue_status} instead of 401." \
      "Verify the local EventSales catalogue endpoint."

  log "WordPress available"
}

dev_database_identity() {
  PGPASSWORD="${EVENTSALES_DEV_DATABASE_PASSWORD}" psql \
    --no-psqlrc --no-align --tuples-only --set=ON_ERROR_STOP=1 \
    --host 127.0.0.1 --port 55432 --username eventsales_dev --dbname event_sales_dev \
    --command "SELECT current_database() || '|' || current_user || '|' || (current_setting('server_version_num')::integer / 10000)::text || '|' || (SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user)" \
    2>/dev/null
}

test_database_identity() {
  PGPASSWORD="${TEST_DATABASE_PASSWORD}" psql \
    --no-psqlrc --no-align --tuples-only --set=ON_ERROR_STOP=1 \
    --host 127.0.0.1 --port "${TEST_DATABASE_PORT}" --username eventsales_test \
    --dbname "${TEST_DATABASE_NAME}" \
    --command "SELECT current_database() || '|' || current_user || '|' || (current_setting('server_version_num')::integer / 10000)::text || '|' || (SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user)" \
    2>/dev/null
}

verify_dev_postgres() {
  pg_isready --host 127.0.0.1 --port 55432 --username eventsales_dev --dbname event_sales_dev >/dev/null ||
    problem "PostgreSQL DEV is unavailable" "127.0.0.1:55432 did not accept connections." \
      "Check the workstation dev-core stack without starting or stopping it from this repository."

  local identity
  identity="$(dev_database_identity || true)"
  [[ "${identity}" == "event_sales_dev|eventsales_dev|18|false" ]] ||
    problem "PostgreSQL DEV identity check failed" \
      "Expected event_sales_dev on PostgreSQL 18 as non-superuser eventsales_dev." \
      "Verify the local role, database, and PostgreSQL DEV endpoint."

  log "PostgreSQL DEV ready (PostgreSQL 18, eventsales_dev/event_sales_dev)"
}

check_redis_endpoint() {
  local port="$1"
  local url_env

  case "${port}" in
    56379) url_env="REDIS_URL" ;;
    56380) url_env="TEST_REDIS_URL" ;;
    *) return 1 ;;
  esac

  EVENTSALES_REDIS_PROBE_URL="${!url_env:-}" \
    python3 "${SCRIPT_DIR}/redis_probe.py" "${port}" ping >/dev/null 2>&1
}

redis_major_version() {
  local port="$1"
  local url_env

  case "${port}" in
    56379) url_env="REDIS_URL" ;;
    56380) url_env="TEST_REDIS_URL" ;;
    *) return 1 ;;
  esac

  EVENTSALES_REDIS_PROBE_URL="${!url_env:-}" \
    python3 "${SCRIPT_DIR}/redis_probe.py" "${port}" version 2>/dev/null
}

verify_redis() {
  local name="$1"
  local port="$2"

  check_redis_endpoint "${port}" ||
    problem "Redis ${name} is unavailable" "127.0.0.1:${port} did not return PONG." \
      "Check the workstation dev-core stack without starting or stopping it from this repository."

  local redis_version
  redis_version="$(redis_major_version "${port}" || true)"
  [[ "${redis_version}" == "7" ]] ||
    problem "Redis ${name} version check failed" "Expected Redis 7 at 127.0.0.1:${port}." \
      "Verify the workstation Redis ${name} service."

  log "Redis ${name} ready (Redis 7)"
}

verify_dev_redis() {
  verify_redis DEV 56379
}

verify_test_redis() {
  verify_redis TEST 56380
}

verify_test_postgres() {
  local database_name="${TEST_DATABASE_NAME:-event_sales_test}"
  pg_isready --host 127.0.0.1 --port 55433 --username eventsales_test --dbname "${database_name}" >/dev/null ||
    problem "PostgreSQL TEST is unavailable" "127.0.0.1:55433 did not accept connections to ${database_name}." \
      "Check the workstation dev-core stack and TEST database allocation without starting or stopping shared services."

  local identity
  identity="$(TEST_DATABASE_NAME="${database_name}" test_database_identity || true)"
  [[ "${identity}" == "${database_name}|eventsales_test|18|false" ]] ||
    problem "PostgreSQL TEST identity check failed" \
      "Expected ${database_name} on PostgreSQL 18 as non-superuser eventsales_test." \
      "Verify the local TEST role, database, and PostgreSQL TEST endpoint."

  log "PostgreSQL TEST ready (PostgreSQL 18, eventsales_test/${database_name})"
}

port_is_open() {
  ss -ltn "sport = :$1" | grep -q LISTEN
}

phoenix_is_reachable() {
  curl --fail --silent --show-error --output /dev/null "${PHOENIX_URL}" 2>/dev/null
}

prepare_runtime() {
  log "Checking local configuration"
  check_tools
  prepare_local_env
  activate_devcore_project
  load_local_env
  validate_local_configuration
  load_catalogue_secret
  export TICKERA_CATALOG_FEED_ENABLED=true
  verify_wordpress

  verify_dev_postgres
  verify_dev_redis

  if [[ ! -d "${REPO_ROOT}/deps" ]]; then
    mix_dev deps.get
  fi

  log "Applying development migrations"
  mix_dev ecto.migrate
}

migrate_dev_command() {
  check_tools
  prepare_local_env
  activate_devcore_project
  load_local_env
  validate_local_configuration
  verify_dev_postgres

  if [[ ! -d "${REPO_ROOT}/deps" ]]; then
    mix_dev deps.get
  fi

  log "Applying development migrations"
  mix_dev ecto.migrate
}

test_command() {
  check_tools
  prepare_local_env
  activate_devcore_project
  load_local_env
  validate_test_configuration

  TEST_DATABASE_NAME="event_sales_test_run_$(date -u +%Y%m%d%H%M%S)_$$"
  export TEST_DATABASE_NAME
  export TEST_DATABASE_HOST=127.0.0.1
  export TEST_DATABASE_PORT=55433

  pg_isready --host 127.0.0.1 --port 55433 --username eventsales_test --dbname postgres >/dev/null ||
    problem "PostgreSQL TEST is unavailable" "127.0.0.1:55433 did not accept connections." \
      "Check the workstation dev-core stack without starting or stopping it from this repository."

  local partition_count=0
  local expect_partition_count=false
  local arg
  local partition_value
  local -a test_args=()

  while (($#)); do
    arg="$1"
    shift

    if [[ "${expect_partition_count}" == "true" ]]; then
      [[ "${arg}" =~ ^[1-9][0-9]*$ ]] ||
        problem "test partition count is invalid" "--partitions requires a positive integer." \
          "Use --partitions N with N greater than zero."
      partition_count="${arg}"
      expect_partition_count=false
    elif [[ "${arg}" == "--partitions" ]]; then
      expect_partition_count=true
    elif [[ "${arg}" == --partitions=* ]]; then
      partition_value="${arg#*=}"
      [[ "${partition_value}" =~ ^[1-9][0-9]*$ ]] ||
        problem "test partition count is invalid" "--partitions requires a positive integer." \
          "Use --partitions N with N greater than zero."
      partition_count="${partition_value}"
    else
      test_args+=("${arg}")
    fi
  done

  [[ "${expect_partition_count}" == "false" ]] ||
    problem "test partition count is missing" "--partitions requires a positive integer." \
      "Use --partitions N with N greater than zero."

  local -a partitions=()
  if [[ "${partition_count}" -gt 0 ]]; then
    local partition
    for ((partition = 1; partition <= partition_count; partition++)); do
      partitions+=("${partition}")
    done
  else
    partitions+=("")
  fi

  local current_partition database_name
  for current_partition in "${partitions[@]}"; do
    database_name="${TEST_DATABASE_NAME}${current_partition}"
    log "Creating and migrating isolated TEST database ${database_name}"

    if [[ -n "${current_partition}" ]]; then
      mix_test_partition "${current_partition}" ecto.create
      mix_test_partition "${current_partition}" ecto.migrate
    else
      mix_test ecto.create
      mix_test ecto.migrate
    fi

    local identity
    identity="$(TEST_DATABASE_NAME="${database_name}" test_database_identity || true)"
    [[ "${identity}" == "${database_name}|eventsales_test|18|false" ]] ||
      problem "PostgreSQL TEST identity check failed" \
        "Expected ${database_name} on PostgreSQL 18 as non-superuser eventsales_test." \
        "Verify the local TEST role, database, and PostgreSQL TEST endpoint."
  done

  if [[ "${partition_count}" -gt 0 ]]; then
    local -a test_pids=()
    local test_status=0
    local pid

    for current_partition in "${partitions[@]}"; do
      mix_test_partition "${current_partition}" test --partitions "${partition_count}" \
        "${test_args[@]}" &
      test_pids+=("$!")
    done

    for pid in "${test_pids[@]}"; do
      if ! wait "${pid}"; then
        test_status=1
      fi
    done

    return "${test_status}"
  else
    mix_test test "${test_args[@]}"
  fi
}

quality_pr_command() {
  check_tools
  prepare_local_env
  activate_devcore_project
  load_local_env
  validate_test_configuration

  TEST_DATABASE_NAME="event_sales_test_run_$(date -u +%Y%m%d%H%M%S)_$$"
  export TEST_DATABASE_NAME
  export TEST_DATABASE_HOST=127.0.0.1
  export TEST_DATABASE_PORT=55433

  pg_isready --host 127.0.0.1 --port 55433 --username eventsales_test --dbname postgres >/dev/null ||
    problem "PostgreSQL TEST is unavailable" "127.0.0.1:55433 did not accept connections." \
      "Check the workstation dev-core stack without starting or stopping it from this repository."

  log "Creating and migrating isolated TEST database ${TEST_DATABASE_NAME} for the full quality gate"
  mix_test ecto.create
  mix_test ecto.migrate

  local identity
  identity="$(test_database_identity || true)"
  [[ "${identity}" == "${TEST_DATABASE_NAME}|eventsales_test|18|false" ]] ||
    problem "PostgreSQL TEST identity check failed" \
      "Expected ${TEST_DATABASE_NAME} on PostgreSQL 18 as non-superuser eventsales_test." \
      "Verify the local TEST role, database, and PostgreSQL TEST endpoint."

  log "Running mix quality.pr against PostgreSQL TEST database ${TEST_DATABASE_NAME}"
  mix_test quality.pr
}

quality_ci_command() {
  check_tools
  prepare_local_env
  activate_devcore_project
  load_local_env
  validate_test_configuration

  TEST_DATABASE_NAME="event_sales_test_ci_$(date -u +%Y%m%d%H%M%S)_$$"
  export TEST_DATABASE_NAME
  export TEST_DATABASE_HOST=127.0.0.1
  export TEST_DATABASE_PORT=55433

  pg_isready --host 127.0.0.1 --port 55433 --username eventsales_test --dbname postgres >/dev/null ||
    problem "PostgreSQL TEST is unavailable" "127.0.0.1:55433 did not accept connections." \
      "Check the workstation dev-core stack without starting or stopping it from this repository."

  log "Creating and migrating isolated TEST database ${TEST_DATABASE_NAME} for the full CI gate"
  mix_test ecto.create
  mix_test ecto.migrate

  local identity
  identity="$(test_database_identity || true)"
  [[ "${identity}" == "${TEST_DATABASE_NAME}|eventsales_test|18|false" ]] ||
    problem "PostgreSQL TEST identity check failed" \
      "Expected ${TEST_DATABASE_NAME} on PostgreSQL 18 as non-superuser eventsales_test." \
      "Verify the local TEST role, database, and PostgreSQL TEST endpoint."

  log "Running mix quality.ci against PostgreSQL TEST database ${TEST_DATABASE_NAME}"
  mix_test quality.ci
}

start_command() {
  prepare_runtime
  configure_phoenix

  if ss -ltn "sport = :${PHOENIX_PORT}" | grep -q LISTEN; then
    if curl --fail --silent --max-time 2 "${PHOENIX_URL}/" >/dev/null 2>&1; then
      printf 'EventSales is already running at %s\n' "${PHOENIX_URL}"
      return 0
    fi

    problem "Port ${PHOENIX_PORT} is occupied by another process." \
      "EventSales cannot bind to ${PHOENIX_URL}." \
      "Inspect with: ss -ltnp 'sport = :${PHOENIX_PORT}'"
  fi

  mkdir -p "$(dirname -- "${PHOENIX_PID_FILE}")"
  printf '%s\n' "$$" >"${PHOENIX_PID_FILE}"
  log "Starting Phoenix at ${PHOENIX_URL}"
  export PORT="${PHOENIX_PORT}"
  exec devcore-project run dev -- env -u MIX_TEST_PARTITION MIX_ENV=dev mix phx.server
}

catalogue_dry_run_command() {
  prepare_runtime
  mix_dev eventsales.catalog.dry_run "$@"
}

status_command() {
  check_tools
  if [[ -f "${REPO_ROOT}/.env.local" ]]; then
    load_local_env
  fi
  configure_phoenix

  if curl --fail --silent --show-error --output /dev/null "${LOCAL_WORDPRESS_URL}" 2>/dev/null; then
    printf 'WordPress: reachable (%s)\n' "${LOCAL_WORDPRESS_URL}"
  else
    printf 'WordPress: unavailable (%s)\n' "${LOCAL_WORDPRESS_URL}"
  fi

  if pg_isready --host 127.0.0.1 --port 55432 --username eventsales_dev --dbname event_sales_dev >/dev/null 2>&1; then
    printf 'PostgreSQL DEV: reachable (127.0.0.1:55432)\n'
  else
    printf 'PostgreSQL DEV: unavailable (127.0.0.1:55432)\n'
  fi

  if pg_isready --host 127.0.0.1 --port 55433 --username eventsales_test --dbname event_sales_test >/dev/null 2>&1; then
    printf 'PostgreSQL TEST: reachable (127.0.0.1:55433)\n'
  else
    printf 'PostgreSQL TEST: unavailable (127.0.0.1:55433)\n'
  fi

  if check_redis_endpoint 56379; then
    printf 'Redis DEV: reachable (127.0.0.1:56379)\n'
  else
    printf 'Redis DEV: unavailable (127.0.0.1:56379)\n'
  fi

  if check_redis_endpoint 56380; then
    printf 'Redis TEST: reachable (127.0.0.1:56380)\n'
  else
    printf 'Redis TEST: unavailable (127.0.0.1:56380)\n'
  fi

  if phoenix_is_reachable; then
    printf 'Phoenix: reachable (%s)\n' "${PHOENIX_URL}"
  else
    printf 'Phoenix: unavailable (%s)\n' "${PHOENIX_URL}"
  fi
}

stop_owned_phoenix() {
  [[ -f "${PHOENIX_PID_FILE}" ]] || return 0

  local pid
  pid="$(<"${PHOENIX_PID_FILE}")"

  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null &&
    grep -aqE 'beam.smp|phx.server' "/proc/${pid}/cmdline" 2>/dev/null; then
    kill "${pid}"
    log "Stopped recorded Phoenix process"
  fi

  rm -f "${PHOENIX_PID_FILE}"
}

stop_command() {
  check_tools
  stop_owned_phoenix
  log "Native Phoenix stopped; workstation PostgreSQL and Redis left untouched"
}

port_status() {
  local port="$1"

  if port_is_open "${port}"; then
    printf 'Port %s: in use\n' "${port}"
  else
    printf 'Port %s: available\n' "${port}"
  fi
}

doctor_command() {
  log "Checking local configuration"
  check_tools

  prepare_local_env
  devcore-project plan
  devcore-project doctor
  devcore-project render
  load_local_env
  configure_phoenix
  validate_local_configuration
  validate_test_configuration
  check_secret_file

  verify_dev_postgres
  verify_dev_redis
  verify_test_postgres
  verify_test_redis

  port_status "${PHOENIX_PORT}"
  port_status 55432
  port_status 55433
  port_status 56379
  port_status 56380
  log "Doctor checks passed"
}

main() {
  local command="${1:-start}"
  shift || true

  case "${command}" in
    start)
      start_command
      ;;
    status)
      status_command
      ;;
    stop)
      stop_command
      ;;
    doctor)
      doctor_command
      ;;
    test)
      test_command "$@"
      ;;
    quality-pr)
      quality_pr_command
      ;;
    quality-ci)
      quality_ci_command
      ;;
    migrate)
      migrate_dev_command
      ;;
    catalogue-dry-run | catalog-dry-run)
      catalogue_dry_run_command "$@"
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
