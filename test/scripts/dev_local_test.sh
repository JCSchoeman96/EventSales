#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCRIPT="${REPO_ROOT}/scripts/dev_local.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  grep -Fq -- "${needle}" "${SCRIPT}" || fail "missing required text: ${needle}"
}

assert_absent() {
  local needle="$1"
  if grep -Fq -- "${needle}" "${SCRIPT}"; then
    fail "forbidden text found: ${needle}"
  fi
}

[[ -f "${SCRIPT}" ]] || fail "scripts/dev_local.sh does not exist"
bash -n "${SCRIPT}"

assert_contains 'local command="${1:-start}"'
assert_contains 'readonly PHOENIX_PORT="${PORT:-4001}"'
assert_contains 'readonly PHOENIX_URL="${EVENTSALES_LOCAL_URL:-http://127.0.0.1:${PHOENIX_PORT}}"'
assert_contains 'export PORT="${PHOENIX_PORT}"'
assert_absent '4000'
assert_contains 'docker compose --env-file /dev/null'
if grep -E '^[[:space:]]*docker compose ' "${SCRIPT}" |
    grep -Fv -- 'docker compose --env-file /dev/null' >/dev/null; then
  fail "every direct Compose invocation must include --env-file /dev/null"
fi
assert_contains 'source "${REPO_ROOT}/.env.local"'
assert_absent 'source "${REPO_ROOT}/.env"'
assert_absent 'source .env'

for flag in \
  CATALOG_AUTO_APPLY_HARD_ENABLED \
  WEBHOOK_REDIS_BUFFER_ENABLED \
  WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED \
  CATALOG_CHANGE_RECEIVER_ENABLED \
  CATALOG_CHANGE_DISPATCHER_ENABLED
do
  assert_contains "${flag}"
done

assert_contains 'TICKERA_CATALOG_FEED_SECRET="$('
assert_absent 'echo "${TICKERA_CATALOG_FEED_SECRET}"'
assert_absent 'printf "${TICKERA_CATALOG_FEED_SECRET}"'
assert_absent 'down -v'
assert_absent 'reset)'

set +e
invalid_output="$(bash "${SCRIPT}" invalid 2>&1)"
invalid_status=$?
set -e

[[ ${invalid_status} -eq 2 ]] || fail "invalid command must exit 2"
[[ "${invalid_output}" == *"Usage:"* ]] || fail "invalid command must print usage"

printf 'dev_local tests passed\n'
