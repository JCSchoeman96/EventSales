#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
wrapper_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres-v2"
sudoers_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres-v2.sudoers"
compose_source="$repo_root/deploy/vps/data-plane/compose.yaml"
bootstrap_source="$repo_root/deploy/vps/data-plane/scripts/bootstrap-postgres.sh"
probe_source="$repo_root/deploy/vps/data-plane/scripts/probe-postgres.sh"
source_sha='c9ce0f9239123a6e58f66fde0b5a1e60238bb107'
compose_sha='3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218'
bootstrap_sha='afa7c663abd06ec109bbb9172f2d5391fa856e3dfbff1a1f90da29a46265fa7f'
probe_sha='3019e4560946957e27f3fca033c754dda1cf9a66adebd61a46208d87b24e77ce'
image='dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19'
expected_command='["-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
historical_command='["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
fixture_uid=$(id -u)
fixture_gid=$(id -g)
passes=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }

[[ -f "$wrapper_source" && ! -L "$wrapper_source" ]] || fail 'bootstrap-v2 wrapper source is missing'
[[ -f "$sudoers_source" && ! -L "$sudoers_source" ]] || fail 'bootstrap-v2 sudoers source is missing'
[[ "$(/usr/bin/sha256sum "$compose_source" | /usr/bin/awk '{print $1}')" == "$compose_sha" ]] || fail 'c9ce Compose identity changed'
[[ "$(/usr/bin/sha256sum "$bootstrap_source" | /usr/bin/awk '{print $1}')" == "$bootstrap_sha" ]] || fail 'c9ce bootstrap child identity changed'
[[ "$(/usr/bin/sha256sum "$probe_source" | /usr/bin/awk '{print $1}')" == "$probe_sha" ]] || fail 'c9ce probe child identity changed'
pass 'c9ce Compose, bootstrap and probe pins match repository history'

tmp_root=$(mktemp -d "/tmp/eventsales-bootstrap-v2.XXXXXX")
fixture=''
cleanup_fixture() {
  if [[ -n "$fixture" && -d "$fixture" ]]; then
    chmod -R u+w "$fixture" 2>/dev/null || true
    rm -rf -- "$fixture"
  fi
  fixture=''
}
cleanup() {
  cleanup_fixture
  chmod -R u+w "$tmp_root" 2>/dev/null || true
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

state_get() { /usr/bin/awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$fixture/state"; }
state_set() {
  local key=$1 value=$2
  /usr/bin/awk -F= -v key="$key" -v value="$value" 'BEGIN { found=0 } $1==key { print key "=" value; found=1; next } { print } END { if (!found) print key "=" value }' "$fixture/state" >"$fixture/state.tmp"
  /usr/bin/mv "$fixture/state.tmp" "$fixture/state"
}

new_fixture() {
  cleanup_fixture
  fixture=$(mktemp -d "$tmp_root/fixture.XXXXXXXX")
  root_fixture="$fixture/root"
  prod_root="$root_fixture/eventsales-prod"
  stage_root="$prod_root/staged/$source_sha"
  stage="$stage_root/data-plane"
  secret_dir="$prod_root/secrets-v1"
  recovery_marker="$prod_root/.v3-postgres-recovery-consumed"
  bootstrap_marker="$prod_root/.v3-postgres-bootstrap-v2-consumed"
  fixture_bin="$fixture/bin"
  wrapper="$fixture/bootstrap-wrapper"
  child_log="$fixture/child.log"
  docker_log="$fixture/docker.log"
  pg_id=$(printf 'a%.0s' {1..64})
  d0_one=$(printf '1%.0s' {1..64})
  d0_two=$(printf '2%.0s' {1..64})
  d0_three=$(printf '3%.0s' {1..64})
  mkdir -p "$stage/scripts" "$secret_dir" "$fixture_bin"
  cp "$compose_source" "$stage/compose.yaml"
  cp "$probe_source" "$stage/scripts/probe-postgres.sh"
  chmod 0444 "$stage/compose.yaml"
  chmod 0555 "$stage/scripts/probe-postgres.sh"
  mkdir -m 0700 "$recovery_marker"
  chmod 0755 "$root_fixture" "$prod_root" "$prod_root/staged" "$stage_root" "$stage"
  printf 'fixture-only\n' >"$secret_dir/postgres_bootstrap_password"
  truncate -s 64 "$secret_dir/postgres_bootstrap_password"
  chmod 0440 "$secret_dir/postgres_bootstrap_password"
  for name in eventsales_migrator_password eventsales_runtime_server_password eventsales_runtime_client_password eventsales_backup_password redis_runtime_password redis_stats_password; do
    truncate -s 64 "$secret_dir/$name"
    chmod 0400 "$secret_dir/$name"
  done
  for name in pgbouncer.ini pgbouncer_users.txt redis-users.acl; do
    printf 'safe fixture\n' >"$secret_dir/$name"
    chmod 0440 "$secret_dir/$name"
  done
  chmod 0700 "$secret_dir"
  : >"$child_log"
  : >"$docker_log"

  cat >"$stage/scripts/bootstrap-postgres.sh" <<'CHILD'
#!/bin/bash
set -euo pipefail
[[ -d 'FIXTURE_BOOTSTRAP_MARKER' && ! -L 'FIXTURE_BOOTSTRAP_MARKER' ]]
[[ "$(/usr/bin/stat -c '%u:%g:%a' 'FIXTURE_BOOTSTRAP_MARKER')" == 'FIXTURE_UID:FIXTURE_GID:700' ]]
printf 'CALL|args=%s|secret=%s|path=%s|home=%s|host=%s|project=%s|config=%s|bash_env=%s\n' \
  "$#" "$1" "$PATH" "$HOME" "$DOCKER_HOST" "${COMPOSE_PROJECT_NAME-}" "${DOCKER_CONFIG-}" "${BASH_ENV-}" >>'FIXTURE_CHILD_LOG'
[[ "$#" -eq 1 && "$1" == 'FIXTURE_SECRET_DIR' ]]
printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_1_ROLES\n'
if [[ "$(/usr/bin/awk -F= '$1=="CHILD_FAIL" {print $2}' 'FIXTURE_STATE')" == yes ]]; then
  printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_2_DATABASE\n'
  exit 42
fi
if [[ "$(/usr/bin/awk -F= '$1=="D0_CHANGE_AFTER_CHILD" {print $2}' 'FIXTURE_STATE')" == status ]]; then
  /usr/bin/sed -i 's/^D0_STATUS=exited$/D0_STATUS=running/' 'FIXTURE_STATE'
fi
if [[ "$(/usr/bin/awk -F= '$1=="D0_CHANGE_AFTER_CHILD" {print $2}' 'FIXTURE_STATE')" == ids ]]; then
  /usr/bin/sed -i 's#^D0_ROWS=.*$#D0_ROWS=FIXTURE_D0_ONE|eventsales-d0-proof-one,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|eventsales-d0-proof-two,FIXTURE_D0_THREE|eventsales-d0-proof-three#' 'FIXTURE_STATE'
fi
if [[ "$(/usr/bin/awk -F= '$1=="D0_CHANGE_AFTER_CHILD" {print $2}' 'FIXTURE_STATE')" == count ]]; then
  /usr/bin/sed -i 's#,FIXTURE_D0_THREE|eventsales-d0-proof-three$##' 'FIXTURE_STATE'
fi
printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_4_PROBE\n'
printf 'POSTGRES_BOOTSTRAP_STATE=BOOTSTRAPPED\n'
CHILD
  /usr/bin/sed -i \
    -e "s|FIXTURE_CHILD_LOG|$child_log|g" \
    -e "s|FIXTURE_SECRET_DIR|$secret_dir|g" \
    -e "s|FIXTURE_BOOTSTRAP_MARKER|$bootstrap_marker|g" \
    -e "s|FIXTURE_UID|$fixture_uid|g" \
    -e "s|FIXTURE_GID|$fixture_gid|g" \
    -e "s|FIXTURE_D0_ONE|$d0_one|g" \
    -e "s|FIXTURE_D0_THREE|$d0_three|g" \
    -e "s|FIXTURE_STATE|$fixture/state|g" \
    "$stage/scripts/bootstrap-postgres.sh"
  chmod 0555 "$stage/scripts/bootstrap-postgres.sh"
  chmod 0555 "$stage/scripts"
  fixture_bootstrap_sha=$(/usr/bin/sha256sum "$stage/scripts/bootstrap-postgres.sh" | /usr/bin/awk '{print $1}')

  cat >"$fixture/state" <<STATE
PG_PRESENT=yes
PG_ID=$pg_id
PG_NAME=eventsales-prod-postgres-1
PG_STATUS=running
PG_RUNNING=true
PG_RESTARTING=false
PG_HEALTH=healthy
PG_RESTARTS=0
PG_OOM=false
PG_IMAGE=$image
PG_MEMORY=3221225472
PG_NANO=2000000000
PG_COMMAND_JSON=$expected_command
PG_MOUNTS=valid
PG_NETWORKS=valid
PG_PORTS=null
PROD_EXTRA=no
DATA_DRIVER=bridge
DATA_INTERNAL=true
VOLUME_PRESENT=yes
VOLUME_NAME=eventsales-prod_postgres_data
VOLUME_DRIVER=local
VOLUME_SCOPE=local
D0_ROWS=$d0_one|eventsales-d0-proof-one,$d0_two|eventsales-d0-proof-two,$d0_three|eventsales-d0-proof-three
D0_STATUS=exited
D0_RUNNING=false
D0_RESTARTING=false
CHILD_FAIL=no
D0_CHANGE_AFTER_CHILD=no
MARKER_MKDIR_FAIL=no
STAT_OVERRIDE_PATH=none
STAT_OVERRIDE_VALUE=none
STATE

  cat >"$fixture_bin/docker" <<'DOCKER'
#!/bin/bash
set -euo pipefail
state='FIXTURE_STATE'
log='FIXTURE_DOCKER_LOG'
get() { /usr/bin/awk -F= -v key="$1" '$1==key{sub(/^[^=]*=/,"");print;exit}' "$state"; }
printf 'ENV|host=%s|context=%s|path=%s|project=%s|secret=%s|config=%s|compose=%s|bash_env=%s\n' \
  "$(/usr/bin/printenv DOCKER_HOST 2>/dev/null || true)" "$(/usr/bin/printenv DOCKER_CONTEXT 2>/dev/null || true)" "$(/usr/bin/printenv PATH 2>/dev/null || true)" "$(/usr/bin/printenv COMPOSE_PROJECT_NAME 2>/dev/null || true)" "$(/usr/bin/printenv EVENTSALES_SECRET_DIR 2>/dev/null || true)" "$(/usr/bin/printenv DOCKER_CONFIG 2>/dev/null || true)" "$(/usr/bin/printenv COMPOSE_FILE 2>/dev/null || true)" "$(/usr/bin/printenv BASH_ENV 2>/dev/null || true)" >>"$log"
printf 'CALL|%s\n' "$*" >>"$log"
case "$1" in
  network)
    [[ "$2" == inspect ]] || exit 90
    name=$5
    if [[ "$name" == eventsales-prod_eventsales_data ]]; then
      printf '%s|%s|%s\n' "$name" "$(get DATA_DRIVER)" "$(get DATA_INTERNAL)"
    else
      printf '%s|%s|%s\n' "$name" wrong false
    fi
    ;;
  volume)
    [[ "$2" == inspect && "$(get VOLUME_PRESENT)" == yes ]] || exit 91
    printf '%s|%s|%s\n' "$(get VOLUME_NAME)" "$(get VOLUME_DRIVER)" "$(get VOLUME_SCOPE)"
    ;;
  ps)
    if [[ "$*" == *eventsales-d0-proof* ]]; then
      /usr/bin/tr ',' '\n' <<<"$(get D0_ROWS)"
    elif [[ "$*" == *com.docker.compose.project=eventsales-prod* ]]; then
      if [[ "$(get PG_PRESENT)" == yes ]]; then printf '%s|%s\n' "$(get PG_ID)" "$(get PG_NAME)"; fi
      if [[ "$(get PROD_EXTRA)" == yes ]]; then printf '%s|eventsales-prod-extra\n' "$(printf 'c%.0s' {1..64})"; fi
    else
      exit 92
    fi
    ;;
  inspect)
    subject=$4
    if [[ "$subject" == "$(get PG_ID)" || "$subject" == "$(get PG_NAME)" ]]; then
      [[ "$(get PG_PRESENT)" == yes ]] || exit 93
      mounts=$(get PG_MOUNTS)
      case "$mounts" in
        valid) mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"ROOT_SECRET/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        wrong-volume) mounts='[{"Type":"volume","Name":"wrong","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"ROOT_SECRET/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        wrong-destination) mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/wrong"},{"Type":"bind","Source":"ROOT_SECRET/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        extra-volume) mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"},{"Type":"volume","Name":"extra","Destination":"/extra"},{"Type":"bind","Source":"ROOT_SECRET/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        missing-volume) mounts='[{"Type":"bind","Source":"ROOT_SECRET/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        wrong-secret) mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"wrong","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        missing-secret) mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"}]' ;;
        malformed) mounts='invalid-json' ;;
        *) exit 94 ;;
      esac
      mounts=$(printf '%s' "$mounts" | /usr/bin/sed "s|ROOT_SECRET|FIXTURE_SECRET|g")
      case "$(get PG_NETWORKS)" in
        valid) networks='{"eventsales-prod_eventsales_data":{}}' ;;
        wrong) networks='{"wrong":{}}' ;;
        extra) networks='{"eventsales-prod_eventsales_data":{},"extra":{}}' ;;
      esac
      printf '%s|/%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$(get PG_ID)" "$(get PG_NAME)" "$(get PG_STATUS)" "$(get PG_RUNNING)" "$(get PG_RESTARTING)" \
        "$(get PG_HEALTH)" "$(get PG_RESTARTS)" "$(get PG_OOM)" "$(get PG_IMAGE)" "$(get PG_MEMORY)" \
        "$(get PG_NANO)" "$(get PG_COMMAND_JSON)" "$mounts" "$networks" "$(get PG_PORTS)"
    else
      found=no
      while IFS= read -r row; do
        id=$(printf '%s' "$row" | /usr/bin/cut -d'|' -f1)
        name=$(printf '%s' "$row" | /usr/bin/cut -d'|' -f2)
        if [[ "$subject" == "$id" ]]; then
          printf '%s|/%s|%s|%s|%s\n' "$id" "$name" "$(get D0_STATUS)" "$(get D0_RUNNING)" "$(get D0_RESTARTING)"
          found=yes
          break
        fi
      done < <(/usr/bin/tr ',' '\n' <<<"$(get D0_ROWS)")
      [[ "$found" == yes ]] || exit 95
    fi
    ;;
  *) exit 96 ;;
esac
DOCKER
  /usr/bin/sed -i \
    -e "s|FIXTURE_STATE|$fixture/state|g" \
    -e "s|FIXTURE_DOCKER_LOG|$docker_log|g" \
    -e "s|FIXTURE_SECRET|$secret_dir|g" \
    "$fixture_bin/docker"
  chmod 0555 "$fixture_bin/docker"

  cat >"$fixture_bin/stat" <<'STAT'
#!/bin/bash
set -euo pipefail
state='FIXTURE_STATE'
format=$2
target=''
for arg in "$@"; do target=$arg; done
override_path=$(/usr/bin/awk -F= '$1=="STAT_OVERRIDE_PATH" {sub(/^[^=]*=/,"");print;exit}' "$state")
override_value=$(/usr/bin/awk -F= '$1=="STAT_OVERRIDE_VALUE" {sub(/^[^=]*=/,"");print;exit}' "$state")
if [[ "$target" == "$override_path" && "$override_value" != none ]]; then
  case "$format" in
    %u:%g:%a) printf '%s\n' "$override_value"; exit 0 ;;
    %u:%g:%a:%s) printf '%s:%s\n' "$override_value" "$(/usr/bin/stat -c '%s' -- "$target")"; exit 0 ;;
  esac
fi
exec /usr/bin/stat "$@"
STAT
  /usr/bin/sed -i "s|FIXTURE_STATE|$fixture/state|g" "$fixture_bin/stat"
  chmod 0555 "$fixture_bin/stat"

  cat >"$fixture_bin/mkdir" <<'MKDIR'
#!/bin/bash
set -euo pipefail
state='FIXTURE_STATE'
target=''
for arg in "$@"; do target=$arg; done
fail=$(/usr/bin/awk -F= '$1=="MARKER_MKDIR_FAIL" {print $2;exit}' "$state")
if [[ "$fail" == yes && "$target" == 'FIXTURE_BOOTSTRAP_MARKER' ]]; then exit 73; fi
exec /usr/bin/mkdir "$@"
MKDIR
  /usr/bin/sed -i -e "s|FIXTURE_STATE|$fixture/state|g" -e "s|FIXTURE_BOOTSTRAP_MARKER|$bootstrap_marker|g" "$fixture_bin/mkdir"
  chmod 0555 "$fixture_bin/mkdir"

  sed \
    -e "s|/root/eventsales-prod|$prod_root|g" \
    -e "s|'/root'|'$root_fixture'|g" \
    -e "s|/usr/sbin:/usr/bin:/sbin:/bin|$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin|g" \
    -e "s|$bootstrap_sha|$fixture_bootstrap_sha|g" \
    -e "s|EUID != 0|EVENTSALES_TEST_EUID != 0|g" \
    -e "s|ROOT_UID=0|ROOT_UID=$fixture_uid|g" \
    -e "s|ROOT_GID=0|ROOT_GID=$fixture_gid|g" \
    -e "s|0:0:700|$fixture_uid:$fixture_gid:700|g" \
    -e "s|0 70 440|$fixture_uid $fixture_gid 440|g" \
    -e "s|0 0 400|$fixture_uid $fixture_gid 400|g" \
    -e "s|0 65532 440|$fixture_uid $fixture_gid 440|g" \
    "$wrapper_source" >"$wrapper"
  chmod 0555 "$wrapper"
}

root_run() { EVENTSALES_TEST_EUID=0 "$wrapper" "$@"; }
nonroot_run() { EVENTSALES_TEST_EUID=65534 "$wrapper"; }

assert_preflight_stop() {
  local label=$1 expected=$2 allow_marker=${3:-no} output status
  if output=$(root_run 2>&1); then fail "$label unexpectedly succeeded"; else status=$?; fi
  ((status != 0)) || fail "$label returned success"
  [[ "$output" == *"STOP=$expected"* ]] || fail "$label returned unexpected output: $output"
  if [[ "$allow_marker" != yes ]]; then
    [[ ! -e "$bootstrap_marker" && ! -L "$bootstrap_marker" ]] || fail "$label consumed bootstrap authority"
  fi
  [[ ! -s "$child_log" ]] || fail "$label invoked the child"
  ! /usr/bin/grep -F -e 'CALL|compose' -e 'CALL|rm ' -e 'CALL|stop ' -e 'CALL|volume create' -e 'CALL|volume rm' -e 'CALL|network create' -e 'CALL|network rm' "$docker_log" >/dev/null || fail "$label attempted a Docker mutation"
  pass "$label"
}

new_fixture
if output=$(root_run extra 2>&1); then fail 'wrapper accepted caller arguments'; fi
[[ "$output" == *'STOP=CALLER_ARGUMENTS_FORBIDDEN'* && ! -s "$docker_log" ]] || fail 'arguments did not stop before Docker'
pass 'rejects caller arguments before Docker'

new_fixture
if output=$(nonroot_run 2>&1); then fail 'wrapper accepted non-root invocation'; fi
[[ "$output" == *'STOP=ROOT_REQUIRED'* ]] || fail "non-root invocation returned unexpected output: $output"
[[ ! -s "$docker_log" ]] || fail 'non-root rejection reached Docker'
pass 'rejects non-root invocation'

new_fixture
PROBE_CALLER_SECRET=must-not-pass COMPOSE_PROJECT_NAME=attacker DOCKER_HOST=tcp://attacker:2375 DOCKER_CONFIG=/tmp/attacker BASH_ENV=/tmp/attacker \
  root_run >"$fixture/stdout" 2>"$fixture/stderr" || { /usr/bin/cat "$fixture/stdout" "$fixture/stderr" "$docker_log"; fail 'valid fixture did not bootstrap'; }
! /usr/bin/grep -E 'attacker|must-not-pass' "$docker_log" "$child_log" >/dev/null || fail 'caller environment reached Docker or child'
pass 'sanitizes Docker and child environments'

new_fixture
chmod -R u+w "$stage"
rm -rf "$stage"
assert_preflight_stop 'requires corrected c9ce stage' C9CE_STAGE_DIRECTORY_MISSING

new_fixture
chmod -R u+w "$stage"
rm -rf "$stage"
ln -s "$stage_root" "$stage"
assert_preflight_stop 'rejects staged data-plane symlink' C9CE_STAGE_DIRECTORY_SYMLINK

new_fixture
state_set STAT_OVERRIDE_PATH "$stage"
state_set STAT_OVERRIDE_VALUE "999:$fixture_gid:755"
assert_preflight_stop 'rejects staged directory ownership drift' C9CE_STAGE_DIRECTORY_OWNER_MISMATCH

new_fixture
chmod 0775 "$stage"
assert_preflight_stop 'rejects writable staged directory' C9CE_STAGE_DIRECTORY_WRITABLE

new_fixture
rm "$stage/compose.yaml"
ln -s "$compose_source" "$stage/compose.yaml"
assert_preflight_stop 'rejects corrected Compose symlink' COMPOSE_SYMLINK

new_fixture
chmod 0644 "$stage/compose.yaml"
assert_preflight_stop 'rejects writable corrected Compose' COMPOSE_WRITABLE

new_fixture
chmod 0644 "$stage/compose.yaml"
printf 'drift\n' >>"$stage/compose.yaml"
chmod 0444 "$stage/compose.yaml"
assert_preflight_stop 'rejects corrected Compose hash drift' COMPOSE_HASH_MISMATCH

new_fixture
state_set STAT_OVERRIDE_PATH "$stage/compose.yaml"
state_set STAT_OVERRIDE_VALUE "999:$fixture_gid:444"
assert_preflight_stop 'rejects corrected Compose ownership drift' COMPOSE_OWNER_MISMATCH

new_fixture
chmod -R u+w "$stage"
rm "$stage/compose.yaml"
mkdir "$stage/compose.yaml"
assert_preflight_stop 'rejects corrected Compose non-file object' COMPOSE_NOT_REGULAR

new_fixture
chmod 0755 "$stage/scripts/bootstrap-postgres.sh"
printf 'changed child\n' >>"$stage/scripts/bootstrap-postgres.sh"
chmod 0555 "$stage/scripts/bootstrap-postgres.sh"
assert_preflight_stop 'rejects bootstrap child hash drift' BOOTSTRAP_SCRIPT_HASH_MISMATCH

new_fixture
chmod -R u+w "$stage/scripts"
mv "$stage/scripts/bootstrap-postgres.sh" "$stage/scripts/bootstrap.real"
ln -s bootstrap.real "$stage/scripts/bootstrap-postgres.sh"
assert_preflight_stop 'rejects bootstrap script symlink' BOOTSTRAP_SCRIPT_SYMLINK

new_fixture
chmod 0444 "$stage/scripts/bootstrap-postgres.sh"
assert_preflight_stop 'rejects non-executable bootstrap script' BOOTSTRAP_SCRIPT_NOT_EXECUTABLE

new_fixture
chmod 0755 "$stage/scripts/bootstrap-postgres.sh"
assert_preflight_stop 'rejects writable bootstrap script' BOOTSTRAP_SCRIPT_WRITABLE

new_fixture
chmod 0755 "$stage/scripts/probe-postgres.sh"
printf 'changed probe\n' >>"$stage/scripts/probe-postgres.sh"
chmod 0555 "$stage/scripts/probe-postgres.sh"
assert_preflight_stop 'rejects probe script hash drift' PROBE_SCRIPT_HASH_MISMATCH

new_fixture
chmod -R u+w "$stage/scripts"
chmod 0555 "$stage/scripts/bootstrap-postgres.sh"
mv "$stage/scripts/probe-postgres.sh" "$stage/scripts/probe.real"
ln -s probe.real "$stage/scripts/probe-postgres.sh"
assert_preflight_stop 'rejects probe script symlink' PROBE_SCRIPT_SYMLINK

new_fixture
rm -rf "$recovery_marker"
assert_preflight_stop 'requires consumed recovery marker' RECOVERY_MARKER_INVALID

new_fixture
rm -rf "$recovery_marker"
touch "$recovery_marker"
assert_preflight_stop 'rejects recovery marker file' RECOVERY_MARKER_INVALID

new_fixture
rm -rf "$recovery_marker"
ln -s "$prod_root" "$recovery_marker"
assert_preflight_stop 'rejects recovery marker symlink' RECOVERY_MARKER_SYMLINK

new_fixture
state_set STAT_OVERRIDE_PATH "$recovery_marker"
state_set STAT_OVERRIDE_VALUE "999:$fixture_gid:700"
assert_preflight_stop 'rejects recovery marker ownership drift' RECOVERY_MARKER_METADATA_MISMATCH

new_fixture
chmod 0750 "$recovery_marker"
assert_preflight_stop 'rejects recovery marker mode drift' RECOVERY_MARKER_METADATA_MISMATCH

new_fixture
mkdir "$bootstrap_marker"
assert_preflight_stop 'rejects consumed bootstrap marker directory' BOOTSTRAP_AUTHORITY_ALREADY_CONSUMED yes

new_fixture
touch "$bootstrap_marker"
assert_preflight_stop 'rejects consumed bootstrap marker file' BOOTSTRAP_AUTHORITY_ALREADY_CONSUMED yes

new_fixture
ln -s "$prod_root" "$bootstrap_marker"
assert_preflight_stop 'rejects consumed bootstrap marker symlink' BOOTSTRAP_AUTHORITY_ALREADY_CONSUMED yes

new_fixture
state_set MARKER_MKDIR_FAIL yes
if output=$(root_run 2>&1); then fail 'marker creation failure unexpectedly bootstrapped'; fi
[[ "$output" == *'STOP=BOOTSTRAP_MARKER_CREATE_FAILED'* && ! -s "$child_log" ]] || fail 'marker failure did not stop before child'
! /usr/bin/grep -F -e 'CALL|compose' -e 'CALL|rm ' -e 'CALL|stop ' -e 'CALL|volume create' -e 'CALL|volume rm' -e 'CALL|network create' -e 'CALL|network rm' "$docker_log" >/dev/null || fail 'marker failure attempted a Docker mutation'
pass 'marker creation failure prevents child invocation'

new_fixture
chmod 0755 "$secret_dir"
assert_preflight_stop 'rejects secret directory metadata drift' SECRET_DIRECTORY_METADATA_MISMATCH

new_fixture
chmod 0400 "$secret_dir/postgres_bootstrap_password"
assert_preflight_stop 'rejects bootstrap secret mode drift' SECRET_FILE_METADATA_MISMATCH

new_fixture
state_set STAT_OVERRIDE_PATH "$secret_dir/postgres_bootstrap_password"
state_set STAT_OVERRIDE_VALUE "$fixture_uid:999:440"
assert_preflight_stop 'rejects bootstrap secret metadata drift' SECRET_FILE_METADATA_MISMATCH

new_fixture
state_set VOLUME_PRESENT no
assert_preflight_stop 'rejects missing production volume' POSTGRES_VOLUME_MISMATCH

new_fixture
state_set VOLUME_NAME replacement-volume
assert_preflight_stop 'rejects replaced production volume identity' POSTGRES_VOLUME_MISMATCH

new_fixture
state_set VOLUME_DRIVER wrong
assert_preflight_stop 'rejects production volume driver drift' POSTGRES_VOLUME_MISMATCH

new_fixture
state_set VOLUME_SCOPE global
assert_preflight_stop 'rejects production volume scope drift' POSTGRES_VOLUME_MISMATCH

new_fixture
state_set DATA_INTERNAL false
assert_preflight_stop 'rejects data-network identity drift' DATA_NETWORK_MISMATCH

new_fixture
state_set PG_PRESENT no
assert_preflight_stop 'rejects missing PostgreSQL' PRODUCTION_INVENTORY_MISMATCH

new_fixture
state_set PG_RUNNING false
state_set PG_STATUS exited
assert_preflight_stop 'rejects stopped PostgreSQL' POSTGRES_NOT_HEALTHY

new_fixture
state_set PG_HEALTH unhealthy
assert_preflight_stop 'rejects unhealthy PostgreSQL' POSTGRES_NOT_HEALTHY

new_fixture
state_set PG_RESTARTING true
assert_preflight_stop 'rejects restarting PostgreSQL' POSTGRES_NOT_HEALTHY

new_fixture
state_set PG_RESTARTS 1
assert_preflight_stop 'rejects restarted PostgreSQL' POSTGRES_RESTART_COUNT_MISMATCH

new_fixture
state_set PG_OOM true
assert_preflight_stop 'rejects OOM-killed PostgreSQL' POSTGRES_OOM_KILLED

new_fixture
state_set PG_IMAGE wrong
assert_preflight_stop 'rejects wrong PostgreSQL image' POSTGRES_IMAGE_MISMATCH

new_fixture
state_set PG_COMMAND_JSON "$historical_command"
assert_preflight_stop 'rejects historical leading postgres command' POSTGRES_COMMAND_MISMATCH

new_fixture
state_set PG_COMMAND_JSON '["-c","shared_buffers=1MB"]'
assert_preflight_stop 'rejects wrong corrected command' POSTGRES_COMMAND_MISMATCH

new_fixture
state_set PG_MEMORY 1
assert_preflight_stop 'rejects resource drift' POSTGRES_RESOURCE_MISMATCH

new_fixture
state_set PG_NANO 1
assert_preflight_stop 'rejects CPU resource drift' POSTGRES_RESOURCE_MISMATCH

new_fixture
state_set PG_ID invalid-id
assert_preflight_stop 'rejects invalid PostgreSQL container ID' PRODUCTION_INVENTORY_MISMATCH

new_fixture
state_set PG_MOUNTS wrong-volume
assert_preflight_stop 'rejects wrong PostgreSQL volume' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_MOUNTS wrong-destination
assert_preflight_stop 'rejects wrong PostgreSQL volume destination' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_MOUNTS extra-volume
assert_preflight_stop 'rejects extra PostgreSQL volume' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_MOUNTS missing-volume
assert_preflight_stop 'rejects missing PostgreSQL volume attachment' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_MOUNTS wrong-secret
assert_preflight_stop 'rejects wrong bootstrap secret mount' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_MOUNTS missing-secret
assert_preflight_stop 'rejects missing bootstrap secret mount' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_MOUNTS malformed
assert_preflight_stop 'rejects malformed runtime attachment JSON' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_NETWORKS wrong
assert_preflight_stop 'rejects wrong PostgreSQL network' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PG_PORTS '{"5432/tcp":[{"HostPort":"5432"}]}'
assert_preflight_stop 'rejects published PostgreSQL ports' POSTGRES_ATTACHMENT_MISMATCH

new_fixture
state_set PROD_EXTRA yes
assert_preflight_stop 'rejects extra production container' PRODUCTION_INVENTORY_MISMATCH

new_fixture
state_set D0_ROWS "$d0_one|eventsales-d0-proof-one,$d0_two|eventsales-d0-proof-two"
assert_preflight_stop 'rejects D0 container count drift' D0_STATE_MISMATCH

new_fixture
state_set D0_ROWS 'bad-id|eventsales-d0-proof-one,'"$d0_two"'|eventsales-d0-proof-two,'"$d0_three"'|eventsales-d0-proof-three'
assert_preflight_stop 'rejects invalid D0 container identity' D0_STATE_MISMATCH

new_fixture
state_set D0_STATUS running
state_set D0_RUNNING true
assert_preflight_stop 'rejects running D0 container' D0_STATE_MISMATCH

new_fixture
state_set D0_RESTARTING true
assert_preflight_stop 'rejects restarting D0 container' D0_STATE_MISMATCH

new_fixture
state_set CHILD_FAIL yes
if output=$(root_run 2>&1); then fail 'child failure was reported as success'; fi
[[ "$output" == *'POSTGRES_BOOTSTRAP_PHASE=PHASE_2_DATABASE'* ]] || fail 'child phase evidence was discarded'
[[ "$output" == *'STOP=BOOTSTRAP_PARTIAL_FAILURE'* ]] || fail 'child failure did not terminate as partial failure'
[[ -d "$bootstrap_marker" && ! -L "$bootstrap_marker" ]] || fail 'consumed marker was removed after child failure'
[[ $(/usr/bin/grep -c '^CALL|' "$child_log") -eq 1 ]] || fail 'child failure was retried'
pass 'child phase failure preserves evidence and one-shot marker without retry'

new_fixture
state_set D0_CHANGE_AFTER_CHILD status
if output=$(root_run 2>&1); then fail 'post-bootstrap D0 drift was accepted'; fi
[[ "$output" == *'STOP=D0_STATE_CHANGED_AFTER_BOOTSTRAP'* ]] || fail 'post-bootstrap D0 drift returned the wrong stop'
[[ -d "$bootstrap_marker" ]] || fail 'post-bootstrap D0 drift cleared consumed marker'
[[ $(/usr/bin/grep -c '^CALL|' "$child_log") -eq 1 ]] || fail 'post-bootstrap check reran child'
pass 'revalidates captured D0 state after child success'

new_fixture
state_set D0_CHANGE_AFTER_CHILD ids
if output=$(root_run 2>&1); then fail 'post-bootstrap D0 ID drift was accepted'; fi
[[ "$output" == *'STOP=D0_STATE_CHANGED_AFTER_BOOTSTRAP'* && -d "$bootstrap_marker" ]] || fail 'post-bootstrap D0 ID drift was not terminal'
[[ $(/usr/bin/grep -c '^CALL|' "$child_log") -eq 1 ]] || fail 'post-bootstrap D0 ID drift reran child'
pass 'rejects D0 ID changes after child success'

new_fixture
state_set D0_CHANGE_AFTER_CHILD count
if output=$(root_run 2>&1); then fail 'post-bootstrap D0 count drift was accepted'; fi
[[ "$output" == *'STOP=D0_STATE_CHANGED_AFTER_BOOTSTRAP'* && -d "$bootstrap_marker" ]] || fail 'post-bootstrap D0 count drift was not terminal'
[[ $(/usr/bin/grep -c '^CALL|' "$child_log") -eq 1 ]] || fail 'post-bootstrap D0 count drift reran child'
pass 'rejects D0 count changes after child success'

new_fixture
CALLER_SENTINEL=must-not-pass DOCKER_HOST=tcp://attacker DOCKER_CONTEXT=attacker DOCKER_CONFIG=/tmp/attacker \
  root_run >"$fixture/stdout" 2>"$fixture/stderr" || fail 'valid fixture failed'
expected_child_env="CALL|args=1|secret=$secret_dir|path=$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin|home=/root|host=unix:///var/run/docker.sock|project=|config=|bash_env="
grep -Fqx "$expected_child_env" "$child_log" || fail 'child did not receive only its fixed environment'
grep -Fq "ENV|host=unix:///var/run/docker.sock|context=|path=$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin|project=|secret=$secret_dir|config=|compose=|bash_env=" "$docker_log" || fail 'Docker did not receive only its fixed environment'
[[ -d "$bootstrap_marker" && ! -L "$bootstrap_marker" ]] || fail 'success did not consume bootstrap marker'
[[ $(/usr/bin/grep -c '^CALL|' "$child_log") -eq 1 ]] || fail 'success did not invoke child exactly once'
[[ "$(state_get PG_PRESENT)" == yes && "$(state_get D0_STATUS)" == exited ]] || fail 'success changed PostgreSQL or D0'
! /usr/bin/grep -E 'attacker|must-not-pass' "$docker_log" "$child_log" >/dev/null || fail 'caller-controlled environment reached Docker or child'
[[ "$(<"$fixture/stdout")" == *'POSTGRES_BOOTSTRAP=BOOTSTRAPPED'* ]] || fail 'success output missing terminal state'
[[ "$(<"$fixture/stdout")" == *'D0_STATE=ARCHIVED_STOPPED'* ]] || fail 'success output missing D0 state'
! /usr/bin/grep -F -e 'CALL|compose' -e 'CALL|rm ' -e 'CALL|stop ' -e 'CALL|volume create' -e 'CALL|volume rm' -e 'CALL|network create' -e 'CALL|network rm' "$docker_log" >/dev/null || fail 'wrapper performed an unauthorized Docker operation'
pass 'success invokes one child and preserves PostgreSQL, D0, and service boundaries'

expected_sudoers='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-bootstrap-postgres-v2 ""'
[[ "$(<"$sudoers_source")" == "$expected_sudoers" ]] || fail 'bootstrap-v2 sudoers rule is not exact'
[[ $(wc -l <"$sudoers_source") -eq 1 ]] || fail 'bootstrap-v2 sudoers has extra lines'
! grep -Eiq 'ALL[[:space:]]*$|/bin/(ba)?sh|docker|\*|install|cp|chmod|chown|mv|rm' "$sudoers_source" || fail 'bootstrap-v2 sudoers grants broader authority'
/usr/sbin/visudo -cf "$sudoers_source" >/dev/null || fail 'visudo rejected bootstrap-v2 sudoers'
pass 'sudoers grants only the exact zero-argument bootstrap-v2 command'

awk '
  /^  vps_deploy_contract:/ { in_job = 1; next }
  in_job && /^  [a-zA-Z0-9_-]+:/ { in_job = 0 }
  in_job && /name: Verify EventSales V3 PostgreSQL bootstrap-v2 wrapper/ { named = 1 }
  in_job && /bash test\/scripts\/agent_eventsales_v3_bootstrap_postgres_v2_test.sh/ { invoked = 1 }
  END { if (named && invoked) exit 0; exit 1 }
' "$repo_root/.github/workflows/ci.yml" || fail 'bootstrap-v2 fake-Docker suite is not wired into the deployment-contract job'
grep -Fq 'BOOTSTRAP_V2_WRAPPER=' "$repo_root/scripts/check_vps_deploy_contract.sh" || fail 'deployment contract does not include bootstrap-v2 wrapper'
grep -Fq 'BOOTSTRAP_V2_SUDOERS=' "$repo_root/scripts/check_vps_deploy_contract.sh" || fail 'deployment contract does not include bootstrap-v2 sudoers'
pass 'CI and deployment contract include bootstrap-v2 authority'

printf 'BOOTSTRAP_V2_TEST=PASS\nBOOTSTRAP_V2_TEST_COUNT=%s\n' "$passes"
