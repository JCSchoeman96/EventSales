#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/bin"

cat >"${tmp_dir}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${DOCKER_CALLS_FILE}"

case "$*" in
  "inspect -f {{.State.Running}} eventsales-postgres-dev")
    echo "false"
    ;;
  "container inspect eventsales-postgres-dev")
    ;;
  "start eventsales-postgres-dev")
    ;;
  "exec eventsales-postgres-dev pg_isready -U postgres -d event_sales_test")
    ;;
  ps\ -a*)
    ;;
  "volume inspect eventsales-postgres-dev-data")
    ;;
  *)
    echo "unexpected docker call: $*" >&2
    exit 64
    ;;
esac
STUB

chmod +x "${tmp_dir}/bin/docker"

export DOCKER_CALLS_FILE="${tmp_dir}/docker-calls.log"
touch "${DOCKER_CALLS_FILE}"

output="$(PATH="${tmp_dir}/bin:${PATH}" "${repo_root}/scripts/dev_postgres.sh" start)"

grep -q "Dev Postgres is ready." <<<"${output}"
grep -q "exec eventsales-postgres-dev pg_isready -U postgres -d event_sales_test" "${DOCKER_CALLS_FILE}"
