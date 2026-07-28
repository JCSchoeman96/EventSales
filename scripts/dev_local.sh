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
  printf 'Usage: bash scripts/dev_local.sh [start|status|stop|doctor|catalogue-dry-run]\n'
}

compose() {
  docker compose --env-file /dev/null "$@"
}

check_tools() {
  local tool

  for tool in docker elixir mix curl ss; do
    command -v "${tool}" >/dev/null 2>&1 ||
      problem "${tool} is unavailable" "Local development requires ${tool}." "Install ${tool} and retry."
  done

  docker compose --env-file /dev/null version >/dev/null 2>&1 ||
    problem "docker compose is unavailable" "The Docker Compose plugin is required." "Install Docker Compose and retry."
}

configure_phoenix() {
  readonly PHOENIX_PORT="${PORT:-4001}"
  readonly PHOENIX_URL="${EVENTSALES_LOCAL_URL:-http://127.0.0.1:${PHOENIX_PORT}}"

  [[ "${PHOENIX_URL}" == "http://127.0.0.1:${PHOENIX_PORT}" ]] ||
    problem "EventSales local URL is invalid" "It must match the configured local Phoenix port." \
      "Set EVENTSALES_LOCAL_URL=http://127.0.0.1:${PHOENIX_PORT} in .env.local."
}

prepare_local_env() {
  if [[ ! -f "${REPO_ROOT}/.env.local" ]]; then
    [[ -f "${REPO_ROOT}/.env.local.example" ]] ||
      problem ".env.local.example is missing" "The local template is required." "Restore .env.local.example."

    cp "${REPO_ROOT}/.env.local.example" "${REPO_ROOT}/.env.local"
    chmod 600 "${REPO_ROOT}/.env.local"
    log "Created .env.local"
  fi
}

load_local_env() {
  # shellcheck disable=SC1091
  set -a
  source "${REPO_ROOT}/.env.local"
  set +a
}

require_local_url() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@]+@)?(localhost|127\.0\.0\.1)(:[0-9]+)?(/.*)?$ ]] ||
    problem "${name} is not local" "${name} must use localhost or 127.0.0.1." "Correct ${name} in .env.local."
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

  require_local_url "DATABASE_URL" "${DATABASE_URL:-}"
  require_local_url "DIRECT_DATABASE_URL" "${DIRECT_DATABASE_URL:-}"
  require_local_url "REDIS_URL" "${REDIS_URL:-}"

  require_disabled "CATALOG_AUTO_APPLY_HARD_ENABLED"
  require_disabled "WEBHOOK_REDIS_BUFFER_ENABLED"
  require_disabled "WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED"
  require_disabled "CATALOG_CHANGE_RECEIVER_ENABLED"
  require_disabled "CATALOG_CHANGE_DISPATCHER_ENABLED"
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
  load_local_env
  validate_local_configuration
  load_catalogue_secret
  export TICKERA_CATALOG_FEED_ENABLED=true
  verify_wordpress

  log "Starting PostgreSQL and Redis"
  compose up -d --wait

  compose exec -T postgres pg_isready -U postgres -d event_sales_dev >/dev/null
  log "PostgreSQL ready"

  local redis_result
  redis_result="$(compose exec -T redis redis-cli ping)"
  [[ "${redis_result}" == "PONG" ]] ||
    problem "Redis health check failed" "Expected PONG." "Inspect Redis with bash scripts/dev_local.sh status."
  log "Redis ready"

  if [[ ! -d "${REPO_ROOT}/deps" ]]; then
    mix deps.get
  fi

  log "Applying migrations"
  mix ecto.create
  mix ecto.migrate
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
  exec mix phx.server
}

catalogue_dry_run_command() {
  prepare_runtime
  mix eventsales.catalog.dry_run
}

compose_service_health() {
  local service="$1"
  local container_id
  container_id="$(compose ps -q "${service}" 2>/dev/null || true)"

  if [[ -z "${container_id}" ]]; then
    printf 'unavailable'
    return
  fi

  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "${container_id}" 2>/dev/null || printf 'unavailable'
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

  printf 'PostgreSQL: %s (127.0.0.1:5432)\n' "$(compose_service_health postgres)"
  printf 'Redis: %s (127.0.0.1:6379)\n' "$(compose_service_health redis)"

  local redis_result
  redis_result="$(compose exec -T redis redis-cli ping 2>/dev/null || true)"
  printf 'Redis ping: %s\n' "${redis_result:-unavailable}"

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
  compose down
  log "PostgreSQL and Redis stopped; named volumes preserved"
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

  [[ -f "${REPO_ROOT}/.env.local" ]] ||
    problem ".env.local is missing" "Doctor does not create local configuration." \
      "Copy .env.local.example to .env.local and set permissions to 600."

  local permissions
  permissions="$(stat -c '%a' "${REPO_ROOT}/.env.local")"
  [[ "${permissions}" == "600" ]] ||
    problem ".env.local permissions are ${permissions}" "Local configuration must be private." \
      "Run chmod 600 .env.local."

  load_local_env
  configure_phoenix
  validate_local_configuration
  check_secret_file
  compose config >/dev/null

  port_status "${PHOENIX_PORT}"
  port_status 5432
  port_status 6379
  log "Doctor checks passed"
}

main() {
  local command="${1:-start}"

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
    catalogue-dry-run | catalog-dry-run)
      catalogue_dry_run_command
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
