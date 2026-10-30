#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
compose_source="$repo_root/deploy/vps/data-plane/compose.yaml"
pgbouncer_source="$repo_root/deploy/vps/data-plane/scripts/probe-pgbouncer.sh"
redis_source="$repo_root/deploy/vps/data-plane/scripts/probe-redis.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/eventsales-staged-probes.XXXXXX")
fixture_bin="$fixture_root/bin"
repository_root="$fixture_root/repository"
repository_data_plane="$repository_root/deploy/vps/data-plane"
stage_root="$fixture_root/immutable-stage"
stage_data_plane="$stage_root/data-plane"
outside_one="$fixture_root/outside-one"
outside_two="$fixture_root/outside-two"
passes=0
failures=0

cleanup() {
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

pass() {
  passes=$((passes + 1))
  printf 'PASS: %s\n' "$1"
}

[[ -f "$compose_source" && ! -L "$compose_source" ]] || { fail 'canonical Compose source is missing or a symlink'; exit 1; }
[[ -f "$pgbouncer_source" && ! -L "$pgbouncer_source" ]] || { fail 'PgBouncer probe source is missing or a symlink'; exit 1; }
[[ -f "$redis_source" && ! -L "$redis_source" ]] || { fail 'Redis probe source is missing or a symlink'; exit 1; }

mkdir -p \
  "$fixture_bin" \
  "$repository_data_plane/scripts" \
  "$stage_data_plane/scripts" \
  "$outside_one" \
  "$outside_two"
cp -- "$compose_source" "$repository_data_plane/compose.yaml"
cp -- "$compose_source" "$stage_data_plane/compose.yaml"
cp -- "$pgbouncer_source" "$repository_data_plane/scripts/probe-pgbouncer.sh"
cp -- "$redis_source" "$repository_data_plane/scripts/probe-redis.sh"
cp -- "$pgbouncer_source" "$stage_data_plane/scripts/probe-pgbouncer.sh"
cp -- "$redis_source" "$stage_data_plane/scripts/probe-redis.sh"
chmod 0444 "$repository_data_plane/compose.yaml" "$stage_data_plane/compose.yaml"

[[ ! -e "$stage_root/deploy/vps/data-plane" ]] || { fail 'staged fixture unexpectedly contains repository-layout fallback'; exit 1; }

cat >"$fixture_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

if (($# != 7)) || [[ "$1" != compose || "$2" != --project-name || "$4" != --file || "$6" != config || "$7" != -q ]]; then
  printf 'FAKE_DOCKER_INVALID_ARGUMENTS=%s\n' "$*" >&2
  exit 70
fi

project=$3
compose_file=$5
if [[ "$compose_file" == /* ]]; then
  resolved_file=$compose_file
else
  resolved_file=$(realpath -m -- "$PWD/$compose_file")
fi
printf 'PROJECT=%s\nFILE=%s\nRESOLVED=%s\nCWD=%s\n' \
  "$project" "$compose_file" "$resolved_file" "$PWD" >"$DOCKER_LOG"
printf 'FAKE_DOCKER_PROJECT=%s\nFAKE_DOCKER_COMPOSE_FILE=%s\n' "$project" "$resolved_file"

[[ "$project" == eventsales-prod ]] || exit 71
[[ "$resolved_file" == "$EXPECTED_SIBLING" ]] || exit 72
[[ -f "$compose_file" && ! -L "$compose_file" ]] || exit 73
DOCKER
chmod 0700 "$fixture_bin/docker"

extract_assignment_block() {
  local source=$1
  local helper=$2

  awk '
    /^readonly EXPECTED_PROJECT=/ { copying = 1 }
    copying { print }
    copying && /^export COMPOSE_PROJECT COMPOSE_FILE$/ { found = 1; exit }
    END { if (!found) exit 1 }
  ' "$source" >"$helper" || return 1
}

extract_compose_function() {
  local source=$1
  local helper=$2

  awk '
    /^compose\(\) \{$/ { copying = 1 }
    copying { print }
    copying && /^\}$/ { found = 1; exit }
    END { if (!found) exit 1 }
  ' "$source" >>"$helper" || return 1
}

write_layout_harness() {
  local source=$1
  local helper=$2

  extract_assignment_block "$source" "$helper" || return 1
  extract_compose_function "$source" "$helper" || return 1
  cat >>"$helper" <<'HARNESS'
printf 'LAYOUT_PROJECT=%s\n' "$COMPOSE_PROJECT"
printf 'LAYOUT_COMPOSE_FILE=%s\n' "$COMPOSE_FILE"
compose config -q
HARNESS
  chmod 0700 "$helper"
}

write_layout_harness "$repository_data_plane/scripts/probe-pgbouncer.sh" \
  "$repository_data_plane/scripts/layout-pgbouncer.sh" || { fail 'could not extract PgBouncer layout harness'; exit 1; }
write_layout_harness "$repository_data_plane/scripts/probe-redis.sh" \
  "$repository_data_plane/scripts/layout-redis.sh" || { fail 'could not extract Redis layout harness'; exit 1; }
write_layout_harness "$stage_data_plane/scripts/probe-pgbouncer.sh" \
  "$stage_data_plane/scripts/layout-pgbouncer.sh" || { fail 'could not extract staged PgBouncer layout harness'; exit 1; }
write_layout_harness "$stage_data_plane/scripts/probe-redis.sh" \
  "$stage_data_plane/scripts/layout-redis.sh" || { fail 'could not extract staged Redis layout harness'; exit 1; }

run_layout_case() {
  local label=$1
  local helper=$2
  local cwd=$3
  local expected_sibling=$4
  local log_file=$5
  local override=${6-}
  local output project compose_file resolved

  if [[ -n "$override" ]]; then
    if ! output=$(cd -- "$cwd" && env \
      -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
      COMPOSE_PROJECT=eventsales-prod COMPOSE_FILE="$override" \
      EXPECTED_SIBLING="$expected_sibling" DOCKER_LOG="$log_file" \
      PATH="$fixture_bin:$PATH" bash "$helper" 2>&1); then
      fail "$label: fake Docker rejected Compose input; output=$output"
      return
    fi
  else
    if ! output=$(cd -- "$cwd" && env \
      -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
      COMPOSE_PROJECT=eventsales-prod EXPECTED_SIBLING="$expected_sibling" \
      DOCKER_LOG="$log_file" PATH="$fixture_bin:$PATH" bash "$helper" 2>&1); then
      fail "$label: fake Docker rejected Compose input; output=$output"
      return
    fi
  fi

  project=$(sed -n 's/^LAYOUT_PROJECT=//p' <<<"$output")
  compose_file=$(sed -n 's/^LAYOUT_COMPOSE_FILE=//p' <<<"$output")
  resolved=$(awk -F= '$1 == "RESOLVED" {sub(/^[^=]*=/, ""); print; exit}' "$log_file")
  if [[ -z "$compose_file" || "$project" != eventsales-prod || "$resolved" != "$expected_sibling" ]]; then
    fail "$label: project or Compose sibling mismatch; project=$project resolved=$resolved expected=$expected_sibling"
    return
  fi
  pass "$label"
}

pg_repo_helper="$repository_data_plane/scripts/layout-pgbouncer.sh"
redis_repo_helper="$repository_data_plane/scripts/layout-redis.sh"
pg_stage_helper="$stage_data_plane/scripts/layout-pgbouncer.sh"
redis_stage_helper="$stage_data_plane/scripts/layout-redis.sh"

run_layout_case PGBOUNCER_REPOSITORY_LAYOUT "$pg_repo_helper" "$repository_root" \
  "$repository_data_plane/compose.yaml" "$fixture_root/pg-repository.log"
run_layout_case REDIS_REPOSITORY_LAYOUT "$redis_repo_helper" "$repository_root" \
  "$repository_data_plane/compose.yaml" "$fixture_root/redis-repository.log"
run_layout_case PGBOUNCER_STAGED_LAYOUT "$pg_stage_helper" "$outside_one" \
  "$stage_data_plane/compose.yaml" "$fixture_root/pg-staged.log"
run_layout_case REDIS_STAGED_LAYOUT "$redis_stage_helper" "$outside_one" \
  "$stage_data_plane/compose.yaml" "$fixture_root/redis-staged.log"
run_layout_case PGBOUNCER_STAGED_SECOND_CWD "$pg_stage_helper" "$outside_two" \
  "$stage_data_plane/compose.yaml" "$fixture_root/pg-staged-second.log"
run_layout_case REDIS_STAGED_SECOND_CWD "$redis_stage_helper" "$outside_two" \
  "$stage_data_plane/compose.yaml" "$fixture_root/redis-staged-second.log"
run_layout_case PGBOUNCER_OPERATOR_COMPOSE_FILE_IGNORED "$pg_stage_helper" "$outside_one" \
  "$stage_data_plane/compose.yaml" "$fixture_root/pg-override.log" "$fixture_root/operator-compose.yaml"
run_layout_case REDIS_OPERATOR_COMPOSE_FILE_IGNORED "$redis_stage_helper" "$outside_one" \
  "$stage_data_plane/compose.yaml" "$fixture_root/redis-override.log" "$fixture_root/operator-compose.yaml"

if ((failures > 0)); then
  printf 'ROOT_CAUSE=STAGED_LAYOUT_COMPOSE_RESOLUTION_FAILED\n' >&2
  printf 'FAILURES=%s\n' "$failures" >&2
  exit 1
fi

assert_layout_source() {
  local label=$1
  local source=$2

  grep -Fqx "COMPOSE_FILE=\"\$DATA_PLANE_DIR/compose.yaml\"" "$source" \
    || fail "$label: Compose path is not the exact sibling"
  if grep -Eq 'REPOSITORY_ROOT|EXPECTED_COMPOSE_FILE|deploy/vps/data-plane/compose.yaml|^cd --? .*REPOSITORY_ROOT' "$source"; then
    fail "$label: repository-layout dependency remains"
  fi
}

assert_layout_source PGBOUNCER "$pgbouncer_source"
assert_layout_source REDIS "$redis_source"

extract_if_block() {
  local source=$1
  local start_line=$2
  local output=$3

  awk -v start_line="$start_line" '
    $0 == start_line { copying = 1 }
    copying { print }
    copying && /^fi$/ { found = 1; exit }
    END { if (!found) exit 1 }
  ' "$source" >>"$output" || return 1
}

write_validation_harness() {
  local source=$1
  local helper=$2

  extract_assignment_block "$source" "$helper" || return 1
  cat >>"$helper" <<'VALIDATION'
report_preflight_failure() {
  printf 'STOP=%s\n' "$1" >&2
  exit 41
}
VALIDATION
  extract_if_block "$source" "if [[ \"\$COMPOSE_PROJECT\" != \"\$EXPECTED_PROJECT\" ]]; then" "$helper" || return 1
  extract_if_block "$source" "if [[ -L \"\$COMPOSE_FILE\" || ! -f \"\$COMPOSE_FILE\" ]]; then" "$helper" || return 1
  printf 'printf "LAYOUT_VALIDATION=PASS\\n"\n' >>"$helper"
  chmod 0700 "$helper"
}

expect_validation_rejection() {
  local label=$1
  local helper=$2
  local cwd=$3
  local expected_stop=$4
  local project=${5:-eventsales-prod}
  local output

  if output=$(cd -- "$cwd" && env -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
    COMPOSE_PROJECT="$project" bash "$helper" 2>&1); then
    fail "$label: invalid layout was accepted"
  elif [[ "$output" == *"STOP=$expected_stop"* ]]; then
    pass "$label"
  else
    fail "$label: unexpected rejection; output=$output"
  fi
}

for probe in pgbouncer redis; do
  if [[ "$probe" == pgbouncer ]]; then
    source="$pgbouncer_source"
    helper="$stage_data_plane/scripts/validate-pgbouncer-layout.sh"
  else
    source="$redis_source"
    helper="$stage_data_plane/scripts/validate-redis-layout.sh"
  fi
  if ! write_validation_harness "$source" "$helper"; then
    fail "$probe: missing project or sibling Compose preflight guard"
    continue
  fi
  if ! (cd -- "$outside_one" && env -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES \
    COMPOSE_PROJECT=eventsales-prod bash "$helper" >/dev/null 2>&1); then
    fail "$probe: valid staged sibling Compose was rejected"
  fi
  expect_validation_rejection "$probe invalid project" "$helper" "$outside_one" \
    COMPOSE_PROJECT_INVALID invalid-project

  mv -- "$stage_data_plane/compose.yaml" "$stage_root/compose.yaml.saved"
  expect_validation_rejection "$probe missing sibling Compose" "$helper" "$outside_one" \
    COMPOSE_FILE_INVALID
  mv -- "$stage_root/compose.yaml.saved" "$stage_data_plane/compose.yaml"

  mv -- "$stage_data_plane/compose.yaml" "$stage_root/compose.yaml.saved"
  ln -s -- "$repository_data_plane/compose.yaml" "$stage_data_plane/compose.yaml"
  expect_validation_rejection "$probe symlink Compose rejected" "$helper" "$outside_one" \
    COMPOSE_FILE_INVALID
  rm -- "$stage_data_plane/compose.yaml"
  mv -- "$stage_root/compose.yaml.saved" "$stage_data_plane/compose.yaml"
done

((failures == 0)) || { printf 'FAILURES=%s\n' "$failures" >&2; exit 1; }

printf 'PGBOUNCER_REPOSITORY_LAYOUT=PASS\n'
printf 'PGBOUNCER_STAGED_LAYOUT=PASS\n'
printf 'REDIS_REPOSITORY_LAYOUT=PASS\n'
printf 'REDIS_STAGED_LAYOUT=PASS\n'
printf 'WORKING_DIRECTORY_INDEPENDENT=PASS\n'
printf 'COMPOSE_SIBLING_REQUIRED=YES\n'
printf 'MISSING_SIBLING_COMPOSE=REJECTED\n'
printf 'SYMLINK_OR_INVALID_LAYOUT=REJECTED_WHERE_CURRENT_CONTRACT_REQUIRES\n'
printf 'TESTS_PASSED=%s\n' "$passes"
