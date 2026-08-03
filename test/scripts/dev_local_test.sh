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
assert_contains 'catalogue-dry-run'
assert_contains 'mix eventsales.catalog.dry_run'
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
assert_absent 'queue_apply'
assert_absent 'ApplyTickeraCatalogWorker'

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/repo/scripts" "${tmp_dir}/repo/deps" "${tmp_dir}/bin"
cp "${SCRIPT}" "${tmp_dir}/repo/scripts/dev_local.sh"
printf 'local-test-secret' >"${tmp_dir}/catalog-secret"

sed \
  -e "s|^EVENTSALES_CATALOG_SECRET_FILE=.*$|EVENTSALES_CATALOG_SECRET_FILE=${tmp_dir}/catalog-secret|" \
  "${REPO_ROOT}/.env.local.example" >"${tmp_dir}/repo/.env.local"
chmod 600 "${tmp_dir}/repo/.env.local"

for command in elixir ss; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"${tmp_dir}/bin/${command}"
  chmod +x "${tmp_dir}/bin/${command}"
done

cat >"${tmp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --write-out "* ]]; then
  printf '401'
fi
EOF
chmod +x "${tmp_dir}/bin/curl"

cat >"${tmp_dir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" redis-cli ping "* ]]; then
  printf 'PONG\n'
fi
EOF
chmod +x "${tmp_dir}/bin/docker"

cat >"${tmp_dir}/bin/mix" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${tmp_dir}/mix-calls"
EOF
chmod +x "${tmp_dir}/bin/mix"

assert_doctor_passes() {
  local description="$1"
  local output
  local status

  set +e
  output="$(PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/repo/scripts/dev_local.sh" doctor 2>&1)"
  status=$?
  set -e

  [[ ${status} -eq 0 ]] || fail "${description}: doctor unexpectedly failed: ${output}"
  [[ "${output}" == *"Doctor checks passed"* ]] ||
    fail "${description}: doctor did not report success"
}

assert_doctor_fails_with() {
  local description="$1"
  local expected="$2"
  local output
  local status

  set +e
  output="$(PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/repo/scripts/dev_local.sh" doctor 2>&1)"
  status=$?
  set -e

  [[ ${status} -ne 0 ]] || fail "${description}: doctor unexpectedly passed"
  [[ "${output}" == *"${expected}"* ]] ||
    fail "${description}: expected output to contain: ${expected}; got: ${output}"
}

assert_doctor_passes "regular mode-600 .env.local"

mv "${tmp_dir}/repo/.env.local" "${tmp_dir}/repo/.env.local-target"
ln -s .env.local-target "${tmp_dir}/repo/.env.local"
assert_doctor_passes "symlink to mode-600 regular .env.local target"

chmod 644 "${tmp_dir}/repo/.env.local-target"
assert_doctor_fails_with "symlink to mode-644 regular .env.local target" \
  ".env.local permissions are 644"

rm "${tmp_dir}/repo/.env.local-target"
assert_doctor_fails_with "dangling .env.local symlink" \
  ".env.local symlink target is unavailable"

mkdir "${tmp_dir}/repo/.env.local-directory"
rm "${tmp_dir}/repo/.env.local"
ln -s .env.local-directory "${tmp_dir}/repo/.env.local"
assert_doctor_fails_with "symlink to .env.local directory" \
  ".env.local is not a regular file"

rm "${tmp_dir}/repo/.env.local"
cp "${REPO_ROOT}/.env.local.example" "${tmp_dir}/repo/.env.local"
chmod 777 "${tmp_dir}/repo/.env.local"
assert_doctor_fails_with "regular mode-777 .env.local" ".env.local permissions are 777"

sed \
  -e "s|^EVENTSALES_CATALOG_SECRET_FILE=.*$|EVENTSALES_CATALOG_SECRET_FILE=${tmp_dir}/catalog-secret|" \
  "${REPO_ROOT}/.env.local.example" >"${tmp_dir}/repo/.env.local"
chmod 600 "${tmp_dir}/repo/.env.local"

PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/repo/scripts/dev_local.sh" catalogue-dry-run

grep -Fxq 'ecto.create' "${tmp_dir}/mix-calls" || fail "catalogue dry-run must create the database"
grep -Fxq 'ecto.migrate' "${tmp_dir}/mix-calls" || fail "catalogue dry-run must migrate the database"
grep -Fxq 'eventsales.catalog.dry_run' "${tmp_dir}/mix-calls" ||
  fail "catalogue dry-run must dispatch to the Mix task"

if grep -Fq 'phx.server' "${tmp_dir}/mix-calls"; then
  fail "catalogue dry-run must not start Phoenix"
fi

: >"${tmp_dir}/mix-calls"
PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/repo/scripts/dev_local.sh" \
  catalogue-dry-run --fresh --source-system-id source-123

grep -Fxq 'eventsales.catalog.dry_run --fresh --source-system-id source-123' \
  "${tmp_dir}/mix-calls" ||
  fail "catalogue dry-run must forward trailing arguments in order"

: >"${tmp_dir}/mix-calls"
PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/repo/scripts/dev_local.sh" \
  catalog-dry-run --fresh

grep -Fxq 'eventsales.catalog.dry_run --fresh' "${tmp_dir}/mix-calls" ||
  fail "catalog-dry-run alias must forward --fresh exactly once"

set +e
invalid_output="$(bash "${SCRIPT}" invalid 2>&1)"
invalid_status=$?
set -e

[[ ${invalid_status} -eq 2 ]] || fail "invalid command must exit 2"
[[ "${invalid_output}" == *"Usage:"* ]] || fail "invalid command must print usage"

printf 'dev_local tests passed\n'
