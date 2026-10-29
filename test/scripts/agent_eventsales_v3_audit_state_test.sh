#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
wrapper_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-audit-state"
sudoers_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-audit-state.sudoers"
historical_sudoers="$repo_root/deploy/vps/operator/agent-eventsales-v3.sudoers"
old_stage='2f69c126ab0098ed2d1323ed33d6bc2761df752f'
new_stage='c9ce0f9239123a6e58f66fde0b5a1e60238bb107'
old_compose_sha='f8d2cee51d6647d7026324ffee8a6ebf82cf8ea7e7a3ed6ca82626cf67b5819f'
postgres_image='dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19'
fixture_uid=$(id -u)
fixture_gid=$(id -g)
passes=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  passes=$((passes + 1))
  printf 'PASS: %s\n' "$1"
}

[[ -f "$wrapper_source" && ! -L "$wrapper_source" ]] || fail 'audit wrapper source is missing'
[[ -f "$sudoers_source" && ! -L "$sudoers_source" ]] || fail 'audit sudoers source is missing'
[[ -f "$historical_sudoers" && ! -L "$historical_sudoers" ]] || fail 'historical V3 sudoers source is missing'

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/eventsales-v3-audit.XXXXXX")
fixture="$tmp_root/fixture"
root_fixture="$fixture/root"
fixture_bin="$fixture/bin"
wrapper_fixture="$tmp_root/agent-eventsales-v3-audit-state"
out="$tmp_root/stdout"
err="$tmp_root/stderr"
docker_log="$tmp_root/docker.log"

cleanup() {
  chmod -R u+w "$tmp_root" 2>/dev/null || true
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

expected_old_dir="$root_fixture/eventsales-prod/staged/$old_stage/data-plane"
expected_new_dir="$root_fixture/eventsales-prod/staged/$new_stage/data-plane"
fixture_state="$fixture/state"

write_state() {
  cat >"$fixture_state" <<STATE
PG_STATUS=exited
PG_RUNNING=false
PG_RESTARTING=false
PG_EXIT_CODE=1
PG_RESTART_COUNT=24
PG_OOM=false
PG_IMAGE=$postgres_image
PG_COMMAND=postgres,-c,max_connections=100,-c,shared_buffers=768MB,-c,effective_cache_size=2GB,-c,work_mem=8MB,-c,maintenance_work_mem=256MB,
PG_MOUNTS=volume:eventsales-prod_postgres_data:/var/lib/postgresql,
PG_NETWORKS=eventsales-prod_eventsales_data,
PG_PORTS=none
VOLUME_EXISTS=yes
DATA_NETWORK_EXISTS=yes
DATA_NETWORK_DRIVER=bridge
DATA_NETWORK_INTERNAL=true
EDGE_NETWORK_EXISTS=yes
EDGE_NETWORK_DRIVER=bridge
EDGE_NETWORK_INTERNAL=false
PRODUCTION_CONTAINERS=eventsales-prod-postgres-1
D0_CONTAINERS=d0-one,d0-two,d0-three
D0_STATUS=exited
D0_RUNNING=false
D0_RESTARTING=false
STAT_UID_OVERRIDE=none
STAT_GID_OVERRIDE=none
STAT_GID_PATH_OVERRIDE=none
STATE
  : >"$docker_log"
}

get_state() {
  /usr/bin/awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$fixture_state"
}

set_state() {
  local key=$1 value=$2
  /usr/bin/awk -F= -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$fixture_state" >"$fixture_state.tmp"
  /usr/bin/mv -- "$fixture_state.tmp" "$fixture_state"
}

make_fixture_filesystem() {
  chmod -R u+w "$root_fixture" 2>/dev/null || true
  rm -rf -- "$root_fixture"
  mkdir -p "$expected_old_dir" "$fixture_bin"
  printf 'fixture historical compose bytes\n' >"$expected_old_dir/compose.yaml"
  chmod 0444 "$expected_old_dir/compose.yaml"
  chmod 0555 "$root_fixture" \
    "$root_fixture/eventsales-prod" \
    "$root_fixture/eventsales-prod/staged" \
    "$root_fixture/eventsales-prod/staged/$old_stage" \
    "$expected_old_dir"
}

mkdir -p "$fixture_bin"
cat >"$fixture_bin/docker" <<'DOCKER'
#!/bin/bash
set -euo pipefail
state='FIXTURE_STATE'
log='FIXTURE_LOG'
get() {
  /usr/bin/awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$state"
}
printf 'ENV|host=%s|context=%s|config=%s|path=%s|project=%s|secret=%s|compose_file=%s|staged_script=%s|target_path=%s|bash_env=%s|env=%s|cdpath=%s\n' \
  "${DOCKER_HOST-}" "${DOCKER_CONTEXT-}" "${DOCKER_CONFIG-}" "${PATH-}" \
  "${COMPOSE_PROJECT_NAME-}" "${EVENTSALES_SECRET_DIR-}" "${COMPOSE_FILE-}" \
  "${STAGED_SCRIPT-}" "${TARGET_PATH-}" "${BASH_ENV-}" "${ENV-}" "${CDPATH-}" >>"$log"
printf 'CALL|%s\n' "$*" >>"$log"

case "${1-}" in
  ps)
    case " $* " in
      *'com.docker.compose.project=eventsales-prod'*)
        printf '%s\n' "$(get PRODUCTION_CONTAINERS)" | /usr/bin/tr ',' '\n' | /usr/bin/sed '/^$/d'
        ;;
      *'name=eventsales-prod'*)
        printf '%s\n' "$(get PRODUCTION_CONTAINERS)" | /usr/bin/tr ',' '\n' | /usr/bin/sed '/^$/d'
        ;;
      *'com.docker.compose.project=eventsales-d0-proof'*)
        printf '%s\n' "$(get D0_CONTAINERS)" | /usr/bin/tr ',' '\n' | /usr/bin/sed '/^$/d'
        ;;
      *) exit 97 ;;
    esac
    ;;
  inspect)
    target=${@: -1}
    case "$target" in
      eventsales-prod-postgres-1)
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
          "$(get PG_STATUS)" "$(get PG_RUNNING)" "$(get PG_RESTARTING)" \
          "$(get PG_EXIT_CODE)" "$(get PG_RESTART_COUNT)" "$(get PG_OOM)" \
          "$(get PG_IMAGE)" "$(get PG_COMMAND)" "$(get PG_MOUNTS)" \
          "$(get PG_NETWORKS)" "$(get PG_PORTS)"
        ;;
      d0-one|d0-two|d0-three)
        printf '%s|%s|%s\n' "$(get D0_STATUS)" "$(get D0_RUNNING)" "$(get D0_RESTARTING)"
        ;;
      *) exit 96 ;;
    esac
    ;;
  volume)
    [[ "${2-}" == inspect ]] || exit 95
    [[ "$(get VOLUME_EXISTS)" == yes ]] || exit 1
    printf 'eventsales-prod_postgres_data\n'
    ;;
  network)
    [[ "${2-}" == inspect ]] || exit 94
    name=${@: -1}
    case "$name" in
      eventsales-prod_eventsales_data)
        [[ "$(get DATA_NETWORK_EXISTS)" == yes ]] || exit 1
        printf '%s|%s|%s\n' "$name" "$(get DATA_NETWORK_DRIVER)" "$(get DATA_NETWORK_INTERNAL)"
        ;;
      eventsales-prod_eventsales_edge)
        [[ "$(get EDGE_NETWORK_EXISTS)" == yes ]] || exit 1
        printf '%s|%s|%s\n' "$name" "$(get EDGE_NETWORK_DRIVER)" "$(get EDGE_NETWORK_INTERNAL)"
        ;;
      *) exit 93 ;;
    esac
    ;;
  *) exit 92 ;;
esac
DOCKER
chmod 0755 "$fixture_bin/docker"

cat >"$fixture_bin/stat" <<'STAT'
#!/bin/bash
set -euo pipefail
state='FIXTURE_STATE'
result=$(/usr/bin/stat "$@")
if [[ "${1-}" == -c && ( "$2" == '%u:%g:%a' || "$2" == '%u:%a' ) ]]; then
  uid=$(/usr/bin/awk -F= '$1 == "STAT_UID_OVERRIDE" { sub(/^[^=]*=/, ""); print; exit }' "$state")
  gid=$(/usr/bin/awk -F= '$1 == "STAT_GID_OVERRIDE" { sub(/^[^=]*=/, ""); print; exit }' "$state")
  gid_path=$(/usr/bin/awk -F= '$1 == "STAT_GID_PATH_OVERRIDE" { sub(/^[^=]*=/, ""); print; exit }' "$state")
  target=${@: -1}
  if [[ "$gid_path" != none && "$target" != "$gid_path" ]]; then
    gid=none
  fi
  IFS=: read -r actual_uid actual_gid mode <<<"$result"
  [[ "$uid" == none ]] || actual_uid=$uid
  if [[ "$2" == '%u:%g:%a' ]]; then
    [[ "$gid" == none ]] || actual_gid=$gid
    printf '%s:%s:%s\n' "$actual_uid" "$actual_gid" "$mode"
  else
    printf '%s:%s\n' "$actual_uid" "$actual_gid"
  fi
else
  printf '%s\n' "$result"
fi
STAT
chmod 0755 "$fixture_bin/stat"

fixture_compose_sha=''
make_fixture_filesystem
fixture_compose_sha=$(/usr/bin/sha256sum "$expected_old_dir/compose.yaml" | /usr/bin/awk '{print $1}')

/usr/bin/sed \
  -e "s|/root|$root_fixture|g" \
  -e "s|readonly SAFE_PATH='/usr/sbin:/usr/bin:/sbin:/bin'|readonly SAFE_PATH='$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin'|" \
  -e "s|readonly ROOT_UID='0'|readonly ROOT_UID='$fixture_uid'|" \
  -e "s|readonly ROOT_GID='0'|readonly ROOT_GID='$fixture_gid'|" \
  -e "s|readonly EXPECTED_COMPOSE_SHA256='$old_compose_sha'|readonly EXPECTED_COMPOSE_SHA256='$fixture_compose_sha'|" \
  -e "s|/usr/bin/stat|$fixture_bin/stat|g" \
  -e 's/((EUID != 0))/((TEST_EUID != 0))/' \
  "$wrapper_source" >"$wrapper_fixture"
chmod 0755 "$wrapper_fixture"

/usr/bin/sed \
  -e "s|FIXTURE_STATE|$fixture_state|g" \
  -e "s|FIXTURE_LOG|$docker_log|g" \
  "$fixture_bin/docker" >"$fixture_bin/docker.tmp"
/usr/bin/mv -- "$fixture_bin/docker.tmp" "$fixture_bin/docker"
chmod 0755 "$fixture_bin/docker"

/usr/bin/sed \
  -e "s|FIXTURE_STATE|$fixture_state|g" \
  "$fixture_bin/stat" >"$fixture_bin/stat.tmp"
/usr/bin/mv -- "$fixture_bin/stat.tmp" "$fixture_bin/stat"
chmod 0755 "$fixture_bin/stat"

run_wrapper() {
  env TEST_EUID=0 \
    EVENTSALES_TEST_SECRET_SENTINEL='AUDIT_TEST_SECRET_MUST_NOT_APPEAR' \
    DOCKER_HOST='tcp://attacker.invalid:2375' \
    DOCKER_CONTEXT='caller-context' \
    DOCKER_CONFIG='/caller/docker-config' \
    PATH='/caller/bin' \
    COMPOSE_PROJECT_NAME='caller-project' \
    EVENTSALES_SECRET_DIR='/caller/secrets' \
    COMPOSE_FILE='/caller/compose.yaml' \
    STAGED_SCRIPT='/caller/script' \
    TARGET_PATH='/caller/target' \
    BASH_ENV='caller-bash-env' \
    ENV='caller-env' \
    CDPATH='/caller/cdpath' \
    "$wrapper_fixture" >"$out" 2>"$err"
}

expect_failure() {
  local name=$1 expected_stop=$2 status
  set +e
  run_wrapper
  status=$?
  set -e
  ((status != 0)) || fail "$name unexpectedly passed"
  grep -Fxq "STOP=$expected_stop" "$err" || { cat "$err" >&2; fail "$name failed for the wrong reason"; }
  pass "$name"
}

reset_case() {
  make_fixture_filesystem
  write_state
}

# The caller argument check runs before filesystem and Docker inspection.
reset_case
set +e
env TEST_EUID=0 "$wrapper_fixture" unexpected >"$out" 2>"$err"
status=$?
set -e
if ((status == 0)) || ! grep -Fxq 'STOP=CALLER_ARGUMENTS_FORBIDDEN' "$err"; then
  fail 'argument rejection is not enforced'
fi
pass 'rejects caller arguments'

# The test copy substitutes EUID only; production still checks Bash EUID.
reset_case
set +e
env TEST_EUID=1000 "$wrapper_fixture" >"$out" 2>"$err"
status=$?
set -e
if ((status == 0)) || ! grep -Fxq 'STOP=ROOT_REQUIRED' "$err"; then
  fail 'root boundary is not enforced'
fi
pass 'rejects non-root execution'

grep -Fq "$old_stage" "$wrapper_source" || fail 'historical stage SHA is not fixed in source'
grep -Fq "$new_stage" "$wrapper_source" || fail 'new stage SHA is not fixed in source'
grep -Fq "$old_compose_sha" "$wrapper_source" || fail 'historical Compose SHA is not fixed in source'
pass 'historical and corrected stage identities are fixed'

reset_case
run_wrapper || { cat "$err" >&2; fail 'valid contained production fixture did not pass'; }
for required in \
  'AUDIT_VERSION=1' \
  'OLD_STAGE_EXISTS=YES' \
  "OLD_STAGE_COMPOSE_SHA256=$fixture_compose_sha" \
  'OLD_STAGE_COMPOSE_MATCH=YES' \
  'NEW_STAGE_EXISTS=NO' \
  'POSTGRES_CONTAINER_EXISTS=YES' \
  'POSTGRES_STATUS=exited' \
  'POSTGRES_RUNNING=false' \
  'POSTGRES_RESTARTING=false' \
  'POSTGRES_EXIT_CODE=1' \
  'POSTGRES_RESTART_COUNT=24' \
  'POSTGRES_OOM_KILLED=false' \
  'POSTGRES_IMAGE_MATCH=YES' \
  'POSTGRES_COMMAND_CLASS=HISTORICAL_BAD_COMMAND' \
  'POSTGRES_VOLUME_ATTACHMENT_MATCH=YES' \
  'POSTGRES_NETWORK_ATTACHMENT_MATCH=YES' \
  'POSTGRES_PORTS_PUBLISHED=NO' \
  'POSTGRES_VOLUME_EXISTS=YES' \
  'DATA_NETWORK_EXISTS=YES' \
  'DATA_NETWORK_DRIVER=bridge' \
  'DATA_NETWORK_INTERNAL=true' \
  'EDGE_NETWORK_EXISTS=YES' \
  'EDGE_NETWORK_DRIVER=bridge' \
  'EDGE_NETWORK_INTERNAL=false' \
  'PRODUCTION_CONTAINER_COUNT=1' \
  'PRODUCTION_CONTAINERS=eventsales-prod-postgres-1' \
  'PGBOUNCER_STARTED=NO' \
  'REDIS_STARTED=NO' \
  'APP_STARTED=NO' \
  'D0_CONTAINER_COUNT=3' \
  'D0_RUNNING_COUNT=0' \
  'D0_RESTARTING_COUNT=0' \
  'D0_STATE=ARCHIVED_STOPPED' \
  'AUDIT_RESULT=PASS'; do
  grep -Fxq "$required" "$out" || fail "successful audit output omitted $required"
done
grep -Fxq "OLD_STAGE_OWNER=$fixture_uid" "$out" || fail 'old stage owner metadata is wrong'
grep -Fxq "OLD_STAGE_GROUP=$fixture_gid" "$out" || fail 'old stage group metadata is wrong'
grep -Fxq 'OLD_STAGE_SYMLINK=NO' "$out" || fail 'old stage symlink status is wrong'
if grep -Eq 'AUDIT_TEST_SECRET_MUST_NOT_APPEAR|CALLER_SECRET|tcp://attacker|caller-context|caller-project|caller/secrets|caller/docker-config|Config\.Env|\{[^}]*\}' "$out"; then
  fail 'audit output exposed caller-controlled, secret, or raw Docker data'
fi
pass 'reports safe deterministic metadata and recognizes historical command'

grep -Fq 'ENV|host=unix:///var/run/docker.sock|' "$docker_log" || fail 'Docker socket is not fixed'
if grep -Eq 'attacker\.invalid|caller-context|caller-project|caller/secrets|caller/docker-config|caller/bin|caller/compose\.yaml|caller/script|caller/target|caller-bash-env|caller-env|caller/cdpath' "$docker_log"; then
  fail 'caller Docker or shell environment reached the Docker client'
fi
if grep -Fq 'Config.Env' "$wrapper_source" || grep -Fq 'Config.Env' "$docker_log"; then
  fail 'wrapper requested Docker environment values'
fi
if grep '^CALL|' "$docker_log" | /usr/bin/awk -F'|' '
  {
    count = split($2, args, /[[:space:]]+/)
    if (args[1] == "ps" || args[1] == "inspect") next
    if ((args[1] == "network" || args[1] == "volume") && args[2] == "inspect") next
    bad = 1
  }
  END { exit !bad }
'; then fail 'a non-read-only Docker command was invoked'; fi
if grep -Eq '(^|[[:space:]])(cp|mv|rm|mkdir|install|chmod|chown|touch|tee|truncate|ln|mount)([[:space:]]|$)' "$wrapper_source"; then
  fail 'wrapper source contains a filesystem mutation command'
fi
pass 'sanitizes caller environment and invokes only read-only Docker operations'

reset_case
chmod u+w "$root_fixture/eventsales-prod/staged/$old_stage"
chmod u+w "$expected_old_dir"
rm -rf -- "$root_fixture/eventsales-prod/staged/$old_stage/data-plane"
ln -s "$fixture/target" "$root_fixture/eventsales-prod/staged/$old_stage/data-plane"
expect_failure 'rejects historical stage symlink' OLD_STAGE_DIRECTORY_SYMLINK

reset_case
set_state STAT_UID_OVERRIDE 65534
expect_failure 'rejects historical directory ownership drift' OLD_STAGE_DIRECTORY_NOT_ROOT_OWNED

reset_case
set_state STAT_GID_OVERRIDE 65534
expect_failure 'rejects historical directory group ownership drift' OLD_STAGE_DIRECTORY_NOT_ROOT_OWNED

reset_case
chmod 0775 "$expected_old_dir"
expect_failure 'rejects historical directory writable mode drift' OLD_STAGE_DIRECTORY_WRITABLE

reset_case
chmod u+w "$expected_old_dir"
rm -- "$expected_old_dir/compose.yaml"
ln -s "$fixture/target-compose" "$expected_old_dir/compose.yaml"
expect_failure 'rejects historical Compose symlink' OLD_COMPOSE_SYMLINK

reset_case
chmod 0644 "$expected_old_dir/compose.yaml"
expect_failure 'rejects writable historical Compose mode' OLD_COMPOSE_WRITABLE

reset_case
set_state STAT_GID_OVERRIDE 65534
set_state STAT_GID_PATH_OVERRIDE "$expected_old_dir/compose.yaml"
expect_failure 'rejects historical Compose group ownership drift' OLD_COMPOSE_NOT_ROOT_OWNED

reset_case
chmod 0644 "$expected_old_dir/compose.yaml"
printf 'changed compose bytes\n' >"$expected_old_dir/compose.yaml"
chmod 0444 "$expected_old_dir/compose.yaml"
expect_failure 'rejects historical Compose hash mismatch' OLD_COMPOSE_HASH_MISMATCH

reset_case
chmod u+w "$root_fixture/eventsales-prod/staged"
mkdir -p "${expected_new_dir%/data-plane}"
expect_failure 'fails closed when corrected stage already exists' NEW_STAGE_ALREADY_EXISTS

reset_case
set_state PG_RUNNING true
set_state PG_STATUS running
expect_failure 'rejects running PostgreSQL' POSTGRES_STATE_MISMATCH

reset_case
set_state PG_RESTARTING true
expect_failure 'rejects restarting PostgreSQL' POSTGRES_STATE_MISMATCH

reset_case
set_state PG_EXIT_CODE 2
expect_failure 'rejects PostgreSQL exit code mismatch' POSTGRES_STATE_MISMATCH

reset_case
set_state PG_RESTART_COUNT 23
expect_failure 'rejects PostgreSQL restart count mismatch' POSTGRES_STATE_MISMATCH

reset_case
set_state PG_OOM true
expect_failure 'rejects OOM-killed PostgreSQL' POSTGRES_STATE_MISMATCH

reset_case
set_state PG_IMAGE 'unexpected/postgres:latest'
expect_failure 'rejects PostgreSQL image mismatch' POSTGRES_IMAGE_MISMATCH

reset_case
set_state PG_MOUNTS 'volume:wrong-volume:/var/lib/postgresql,'
expect_failure 'rejects wrong PostgreSQL volume attachment' POSTGRES_VOLUME_ATTACHMENT_MISMATCH

reset_case
set_state PG_NETWORKS 'eventsales-prod_eventsales_edge,'
expect_failure 'rejects wrong PostgreSQL network attachment' POSTGRES_NETWORK_ATTACHMENT_MISMATCH

reset_case
set_state PG_PORTS published
expect_failure 'rejects published PostgreSQL ports' POSTGRES_PORTS_PUBLISHED

reset_case
set_state VOLUME_EXISTS no
expect_failure 'rejects missing PostgreSQL volume' POSTGRES_VOLUME_MISSING

reset_case
set_state DATA_NETWORK_INTERNAL false
expect_failure 'rejects data-network contract mismatch' PRODUCTION_NETWORK_MISMATCH

reset_case
set_state EDGE_NETWORK_DRIVER overlay
expect_failure 'rejects edge-network contract mismatch' PRODUCTION_NETWORK_MISMATCH

reset_case
set_state DATA_NETWORK_EXISTS no
expect_failure 'rejects missing data network' PRODUCTION_NETWORK_MISMATCH

reset_case
set_state EDGE_NETWORK_EXISTS no
expect_failure 'rejects missing edge network' PRODUCTION_NETWORK_MISMATCH

for service in pgbouncer redis app unknown; do
  reset_case
  set_state PRODUCTION_CONTAINERS "eventsales-prod-postgres-1,eventsales-prod-$service-1"
  expect_failure "rejects unexpected $service container" UNEXPECTED_PRODUCTION_CONTAINER
done

reset_case
set_state D0_RUNNING true
expect_failure 'rejects running D0 container' D0_NOT_ARCHIVED

reset_case
set_state D0_RESTARTING true
expect_failure 'rejects restarting D0 container' D0_NOT_ARCHIVED

grep -Fq 'agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-audit-state ""' "$sudoers_source" || fail 'sudoers does not contain the exact zero-argument authority'
sudoers_rules=$(/usr/bin/awk 'NF && $1 !~ /^#/ { print }' "$sudoers_source")
[[ "$sudoers_rules" == 'agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-audit-state ""' ]] || fail 'sudoers grants broader or additional authority'
grep -Fq 'docker' "$sudoers_source" && fail 'sudoers grants Docker directly'
verify_historical_sha() {
  local path=$1 expected=$2 actual
  actual=$(/usr/bin/sha256sum -- "$repo_root/$path" | /usr/bin/awk '{print $1}')
  [[ "$actual" == "$expected" ]] || fail "historical V3 authority changed: $path"
}

verify_historical_sha \
  deploy/vps/operator/agent-eventsales-v3-provision-networks \
  4ede4ad5ae0696ee605bd890e3ced9a18d8d5ac4c7a11992325823de7e5cdad3
verify_historical_sha \
  deploy/vps/operator/agent-eventsales-v3-start-postgres \
  b054b6e97da5e8455615534273168fe4322ce7f6800a5b6486892027df33b567
verify_historical_sha \
  deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres \
  b763431776faf81a8cc84b61c494b3ed22bb8bf732962306973878e83fae79ab
verify_historical_sha \
  deploy/vps/operator/agent-eventsales-v3.sudoers \
  8575c6c1e85d111bb78b360b8e03f2c9f6e6a1dfccc5fbc0273003a354bc51d3
pass 'sudoers grants only the zero-argument audit wrapper'

[[ $(wc -l <"$docker_log") -gt 0 ]] || fail 'fake Docker did not observe inspection calls'
if grep -Fq 'CALL|compose' "$docker_log"; then fail 'wrapper invoked Docker Compose'; fi
pass 'fixture confirms no Docker mutation or Compose operation'

printf 'AUDIT_TEST=PASS\nAUDIT_TEST_COUNT=%s\n' "$passes"
