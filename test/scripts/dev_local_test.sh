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
assert_contains 'mix_dev eventsales.catalog.dry_run'
assert_contains 'devcore-project plan'
assert_contains 'devcore-project activate'
assert_contains 'devcore-project run dev --'
assert_contains 'devcore-project run test --'
assert_contains 'quality_pr_command'
assert_contains 'quality_ci_command'
assert_contains 'readonly PHOENIX_PORT="${PORT:-4001}"'
assert_contains 'readonly PHOENIX_URL="${EVENTSALES_LOCAL_URL:-http://127.0.0.1:${PHOENIX_PORT}}"'
assert_contains 'export PORT="${PHOENIX_PORT}"'
assert_absent '4000'
assert_absent 'docker compose'
assert_absent 'docker '
assert_absent 'redis-cli'
assert_contains '55432'
assert_contains '55433'
assert_contains '56379'
assert_contains '56380'
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
if grep -Eq '^TICKERA_CATALOG_FEED_SECRET=' "${REPO_ROOT}/.env.local.example"; then
  fail "catalogue secrets must come from the local secret file, not the rendered env file"
fi
if grep -Eq '^TICKERA_CATALOG_FEED_ENABLED=' "${REPO_ROOT}/.env.local.example"; then
  fail "the local script must control catalogue feed enablement for each command"
fi
grep -Fq 'TICKERA_CATALOG_FEED_SECRET' "${REPO_ROOT}/.devcore/render-map.tsv" ||
  fail "bootstrap must purge any stale catalogue secret from .env.local"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/repo/scripts" "${tmp_dir}/repo/deps" "${tmp_dir}/bin"
export DEVCORE_CALLS_FILE="${tmp_dir}/devcore-calls"
export REAL_PYTHON3_BIN="$(command -v python3)"
cp "${SCRIPT}" "${tmp_dir}/repo/scripts/dev_local.sh"
cp "${REPO_ROOT}/.env.local.example" "${tmp_dir}/repo/.env.local.example"
printf 'local-test-secret' >"${tmp_dir}/catalog-secret"

sed \
  -e "s|^EVENTSALES_CATALOG_SECRET_FILE=.*$|EVENTSALES_CATALOG_SECRET_FILE=${tmp_dir}/catalog-secret|" \
  -e 's|^TEST_DATABASE_NAME=.*$|TEST_DATABASE_NAME=event_sales_test_smoke|' \
  "${REPO_ROOT}/.env.local.example" >"${tmp_dir}/repo/.env.local"
chmod 600 "${tmp_dir}/repo/.env.local"

for command in elixir ss pg_isready; do
  cat >"${tmp_dir}/bin/${command}" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"\${${command^^}_CALLS_FILE:-/dev/null}"
exit 0
EOF
  chmod +x "${tmp_dir}/bin/${command}"
done

cat >"${tmp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --write-out "* ]]; then
  printf '401'
fi
EOF
chmod +x "${tmp_dir}/bin/curl"

cat >"${tmp_dir}/bin/psql" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PSQL_CALLS_FILE:-/dev/null}"
database=""
username=""
while (($#)); do
  case "$1" in
    --dbname) database="$2"; shift 2 ;;
    --username) username="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s|%s|18|false\n' "$database" "$username"
EOF
chmod +x "${tmp_dir}/bin/psql"

cat >"${tmp_dir}/bin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" != *"redis_probe.py"* ]]; then
  exec "${REAL_PYTHON3_BIN}" "$@"
fi
printf '%s\n' "$*" >>"${REDIS_PROBE_CALLS_FILE:-/dev/null}"
if [[ " $* " == *" version "* ]]; then
  printf '7\n'
else
  printf 'PONG\n'
fi
EOF
chmod +x "${tmp_dir}/bin/python3"

cat >"${tmp_dir}/bin/mix" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${tmp_dir}/mix-calls"
printf '%s|%s|%s\n' "\$*" "\${MIX_ENV:-unset}" "\${MIX_TEST_PARTITION:-unset}" \
  >>"\${MIX_ENV_CALLS_FILE:-/dev/null}"
EOF
chmod +x "${tmp_dir}/bin/mix"

cat >"${tmp_dir}/bin/devcore-project" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DEVCORE_CALLS_FILE:-/dev/null}"
if [[ "${1:-}" == "run" ]]; then
  shift 3
  exec "$@"
fi
EOF
chmod +x "${tmp_dir}/bin/devcore-project"

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

cat >"${tmp_dir}/repo/.env.local" <<'EOF'
EVENTSALES_DEV_DATABASE_USERNAME=eventsales_dev
EVENTSALES_DEV_DATABASE_PASSWORD=dev-bootstrap-placeholder
TEST_DATABASE_USERNAME=eventsales_test
TEST_DATABASE_PASSWORD=test-bootstrap-placeholder
TEST_DATABASE_HOST=127.0.0.1
TEST_DATABASE_PORT=55433
TEST_DATABASE_NAME=event_sales_test
REDIS_URL=redis://127.0.0.1:56379/0
TEST_REDIS_URL=redis://127.0.0.1:56380/0
WEBHOOK_RATE_LIMIT_REDIS_URL=redis://127.0.0.1:56379/0
EOF
chmod 600 "${tmp_dir}/repo/.env.local"
assert_doctor_passes "sparse bootstrap-generated .env.local"
grep -Fq 'TICKERA_CATALOG_FEED_BASE_URL=http://localhost:10059' "${tmp_dir}/repo/.env.local" ||
  fail "local defaults must be restored after devcore-project creates a sparse env file"

sed \
  -e "s|^EVENTSALES_CATALOG_SECRET_FILE=.*$|EVENTSALES_CATALOG_SECRET_FILE=${tmp_dir}/catalog-secret|" \
  -e 's|^TEST_DATABASE_NAME=.*$|TEST_DATABASE_NAME=event_sales_test_smoke|' \
  "${REPO_ROOT}/.env.local.example" >"${tmp_dir}/repo/.env.local"
chmod 600 "${tmp_dir}/repo/.env.local"

: >"${tmp_dir}/pg_isready-calls"
: >"${tmp_dir}/psql-calls"
MIX_TEST_PARTITION=2 \
PG_ISREADY_CALLS_FILE="${tmp_dir}/pg_isready-calls" \
PSQL_CALLS_FILE="${tmp_dir}/psql-calls" \
PATH="${tmp_dir}/bin:${PATH}" \
  bash "${tmp_dir}/repo/scripts/dev_local.sh" doctor >/dev/null

grep -Fq -- '--dbname event_sales_test_smoke' "${tmp_dir}/pg_isready-calls" ||
  fail "doctor must probe the configured TEST database"
grep -Fq -- '--dbname event_sales_test_smoke' "${tmp_dir}/psql-calls" ||
  fail "doctor identity check must use the configured TEST database"
if grep -Fq -- '--dbname event_sales_test_smoke2' \
  "${tmp_dir}/pg_isready-calls" "${tmp_dir}/psql-calls"; then
  fail "doctor must not apply a test partition suffix to the configured TEST database"
fi

mv "${tmp_dir}/repo/.env.local" "${tmp_dir}/repo/.env.local-target"
ln -s .env.local-target "${tmp_dir}/repo/.env.local"
assert_doctor_fails_with "symlink to mode-600 regular .env.local target" \
  ".env.local must be a regular file"

chmod 644 "${tmp_dir}/repo/.env.local-target"
assert_doctor_fails_with "symlink to mode-644 regular .env.local target" \
  ".env.local must be a regular file"

rm "${tmp_dir}/repo/.env.local-target"
assert_doctor_fails_with "dangling .env.local symlink" \
  ".env.local must be a regular file"

mkdir "${tmp_dir}/repo/.env.local-directory"
rm "${tmp_dir}/repo/.env.local"
ln -s .env.local-directory "${tmp_dir}/repo/.env.local"
assert_doctor_fails_with "symlink to .env.local directory" \
  ".env.local must be a regular file"

rm "${tmp_dir}/repo/.env.local"
cp "${REPO_ROOT}/.env.local.example" "${tmp_dir}/repo/.env.local"
chmod 777 "${tmp_dir}/repo/.env.local"
assert_doctor_fails_with "regular mode-777 .env.local" ".env.local permissions are 777"

sed \
  -e "s|^EVENTSALES_CATALOG_SECRET_FILE=.*$|EVENTSALES_CATALOG_SECRET_FILE=${tmp_dir}/catalog-secret|" \
  "${REPO_ROOT}/.env.local.example" >"${tmp_dir}/repo/.env.local"
chmod 600 "${tmp_dir}/repo/.env.local"

PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/repo/scripts/dev_local.sh" catalogue-dry-run

grep -Fxq 'plan' "${tmp_dir}/devcore-calls" || fail "local runtime must resolve the dev-core contract"
grep -Fxq 'activate' "${tmp_dir}/devcore-calls" || fail "local runtime must activate the worktree dev-core allocation"
grep -Fxq 'run dev -- env -u MIX_TEST_PARTITION MIX_ENV=dev mix eventsales.catalog.dry_run' \
  "${tmp_dir}/devcore-calls" || fail "development Mix tasks must run through devcore-project"

grep -Fxq 'ecto.migrate' "${tmp_dir}/mix-calls" || fail "catalogue dry-run must migrate the development database"
if grep -Fxq 'ecto.create' "${tmp_dir}/mix-calls"; then
  fail "local startup must not create a database outside the workstation infrastructure owner"
fi
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

: >"${tmp_dir}/mix-calls"
: >"${tmp_dir}/mix-env-calls"
MIX_ENV=test \
MIX_ENV_CALLS_FILE="${tmp_dir}/mix-env-calls" \
PATH="${tmp_dir}/bin:${PATH}" \
  bash "${tmp_dir}/repo/scripts/dev_local.sh" migrate
grep -Fxq 'ecto.migrate|dev|unset' "${tmp_dir}/mix-env-calls" ||
  fail "development migration must force MIX_ENV=dev and clear test partition state"

: >"${tmp_dir}/mix-calls"
: >"${tmp_dir}/pg_isready-calls"
: >"${tmp_dir}/psql-calls"
: >"${tmp_dir}/redis-probe-calls"
: >"${tmp_dir}/mix-env-calls"
PSQL_CALLS_FILE="${tmp_dir}/psql-calls" \
  PG_ISREADY_CALLS_FILE="${tmp_dir}/pg_isready-calls" \
  REDIS_PROBE_CALLS_FILE="${tmp_dir}/redis-probe-calls" \
  MIX_ENV_CALLS_FILE="${tmp_dir}/mix-env-calls" \
  PATH="${tmp_dir}/bin:${PATH}" \
  bash "${tmp_dir}/repo/scripts/dev_local.sh" test test/example_test.exs

grep -Fxq 'plan' "${tmp_dir}/devcore-calls" || fail "test runner must resolve the dev-core contract"
grep -Fxq 'activate' "${tmp_dir}/devcore-calls" || fail "test runner must activate the worktree dev-core allocation"
grep -Eq '^run test -- env -u MIX_TEST_PARTITION MIX_ENV=test TEST_DATABASE_NAME=event_sales_test_run_[^ ]+ mix ecto.create$' \
  "${tmp_dir}/devcore-calls" || fail "TEST Mix tasks must run through devcore-project with the isolated database"

grep -Fxq 'ecto.create' "${tmp_dir}/mix-calls" ||
  fail "local tests must create an isolated TEST database"
grep -Fxq 'ecto.migrate' "${tmp_dir}/mix-calls" ||
  fail "local tests must migrate the TEST database"
grep -Fxq 'test test/example_test.exs' "${tmp_dir}/mix-calls" ||
  fail "local test runner must forward focused test paths"
if grep -q -- '--port 55432' "${tmp_dir}/psql-calls" "${tmp_dir}/pg_isready-calls"; then
  fail "local tests must not connect to the PostgreSQL DEV endpoint"
fi
if grep -q -- '--port 55433' "${tmp_dir}/psql-calls" "${tmp_dir}/pg_isready-calls"; then
  :
else
  fail "local test runner must connect to the PostgreSQL TEST endpoint"
fi
if [[ -s "${tmp_dir}/redis-probe-calls" ]]; then
  fail "local tests must not connect to shared Redis"
fi

: >"${tmp_dir}/mix-calls"
: >"${tmp_dir}/pg_isready-calls"
: >"${tmp_dir}/psql-calls"
: >"${tmp_dir}/redis-probe-calls"
: >"${tmp_dir}/mix-env-calls"
PSQL_CALLS_FILE="${tmp_dir}/psql-calls" \
  PG_ISREADY_CALLS_FILE="${tmp_dir}/pg_isready-calls" \
  REDIS_PROBE_CALLS_FILE="${tmp_dir}/redis-probe-calls" \
  MIX_ENV_CALLS_FILE="${tmp_dir}/mix-env-calls" \
  PATH="${tmp_dir}/bin:${PATH}" \
  bash "${tmp_dir}/repo/scripts/dev_local.sh" test --partitions 2

partition_database_count="$(grep -Eo -- '--dbname event_sales_test_run_[^ ]+' "${tmp_dir}/psql-calls" | sort -u | wc -l)"
[[ "${partition_database_count}" -eq 2 ]] ||
  fail "parallel local test partitions must use unique TEST database names"
grep -Fxq 'test --partitions 2' "${tmp_dir}/mix-calls" ||
  fail "local test runner must preserve the Mix partition count"
grep -Fxq 'test --partitions 2|test|1' "${tmp_dir}/mix-env-calls" ||
  fail "first partition must run in its unique MIX_TEST_PARTITION=1 process"
grep -Fxq 'test --partitions 2|test|2' "${tmp_dir}/mix-env-calls" ||
  fail "second partition must run in its unique MIX_TEST_PARTITION=2 process"

: >"${tmp_dir}/mix-calls"
: >"${tmp_dir}/pg_isready-calls"
: >"${tmp_dir}/psql-calls"
PSQL_CALLS_FILE="${tmp_dir}/psql-calls" \
  PG_ISREADY_CALLS_FILE="${tmp_dir}/pg_isready-calls" \
  PATH="${tmp_dir}/bin:${PATH}" \
  bash "${tmp_dir}/repo/scripts/dev_local.sh" quality-pr
grep -Fxq 'ecto.create' "${tmp_dir}/mix-calls" ||
  fail "the local quality gate must create its isolated TEST database"
grep -Fxq 'ecto.migrate' "${tmp_dir}/mix-calls" ||
  fail "the local quality gate must migrate its isolated TEST database"
grep -Fxq 'quality.pr' "${tmp_dir}/mix-calls" ||
  fail "the local quality gate must run the established PR quality alias"
if grep -q -- '--port 55432' "${tmp_dir}/psql-calls" "${tmp_dir}/pg_isready-calls"; then
  fail "the local quality gate must not connect to the PostgreSQL DEV endpoint"
fi

: >"${tmp_dir}/mix-calls"
: >"${tmp_dir}/pg_isready-calls"
: >"${tmp_dir}/psql-calls"
PSQL_CALLS_FILE="${tmp_dir}/psql-calls" \
  PG_ISREADY_CALLS_FILE="${tmp_dir}/pg_isready-calls" \
  PATH="${tmp_dir}/bin:${PATH}" \
  bash "${tmp_dir}/repo/scripts/dev_local.sh" quality-ci
grep -Fxq 'quality.ci' "${tmp_dir}/mix-calls" ||
  fail "the local CI gate must run the established CI quality alias"
grep -Eq -- '--dbname event_sales_test_ci_' "${tmp_dir}/psql-calls" ||
  fail "the local CI gate must use a unique TEST database"
if grep -q -- '--port 55432' "${tmp_dir}/psql-calls" "${tmp_dir}/pg_isready-calls"; then
  fail "the local CI quality gate must not connect to the PostgreSQL DEV endpoint"
fi

set +e
invalid_output="$(bash "${SCRIPT}" invalid 2>&1)"
invalid_status=$?
set -e

[[ ${invalid_status} -eq 2 ]] || fail "invalid command must exit 2"
[[ "${invalid_output}" == *"Usage:"* ]] || fail "invalid command must print usage"

mkdir -p "${tmp_dir}/backup-bin"
for command in pg_dump psql pg_restore createdb dropdb mix; do
  cat >"${tmp_dir}/backup-bin/${command}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${tmp_dir}/backup-bin/${command}"
done

mkdir -p "${tmp_dir}/backup-repo/scripts"
cp "${REPO_ROOT}/scripts/verify_backup_restore.sh" \
  "${tmp_dir}/backup-repo/scripts/verify_backup_restore.sh"
git -C "${tmp_dir}/backup-repo" init -q
printf 'TEST_DATABASE_PASSWORD=must-not-load-root-env\n' >"${tmp_dir}/backup-repo/.env"
ln -s .env "${tmp_dir}/backup-repo/.env.local"

set +e
backup_output="$(cd "${tmp_dir}/backup-repo" && PATH="${tmp_dir}/backup-bin:${PATH}" \
  bash scripts/verify_backup_restore.sh 2>&1)"
backup_status=$?
set -e

[[ ${backup_status} -ne 0 ]] || fail "backup verification must reject a .env.local symlink"
[[ "${backup_output}" == *".env.local must be a regular file"* ]] ||
  fail "backup verification must reject a .env.local symlink before running commands"
[[ "${backup_output}" != *"must-not-load-root-env"* ]] ||
  fail "backup verification must not expose values from a root .env symlink"

printf 'dev_local tests passed\n'
