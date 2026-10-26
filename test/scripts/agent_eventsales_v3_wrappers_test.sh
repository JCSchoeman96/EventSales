#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
provision_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-provision-networks"
start_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-start-postgres"
bootstrap_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres"
sudoers_source="$repo_root/deploy/vps/operator/agent-eventsales-v3.sudoers"
expected_stage='/root/eventsales-prod/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane'
expected_secret_dir='/root/eventsales-prod/secrets-v1'
secret_sentinel='V3_FIXTURE_SECRET_VALUE_MUST_NEVER_BE_PRINTED'
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

for source in "$provision_source" "$start_source" "$bootstrap_source" "$sudoers_source"; do
  [[ -f "$source" && ! -L "$source" ]] || fail 'required V3 wrapper or sudoers source is missing'
done

for wrapper_source in "$provision_source" "$start_source" "$bootstrap_source"; do
  grep -Fq 'if ((EUID != 0)); then' "$wrapper_source" || fail 'source wrapper is missing its actual root boundary'
done
pass 'source wrappers retain the actual root boundary'

grep -Fq "$expected_stage/scripts/provision-networks.sh" "$provision_source" || fail 'network wrapper does not use the fixed staged provisioner'
grep -Fq "$expected_stage/compose.yaml" "$start_source" || fail 'PostgreSQL start wrapper does not use the fixed Compose file'
grep -Fq "$expected_stage/scripts/bootstrap-postgres.sh" "$bootstrap_source" || fail 'bootstrap wrapper does not use the fixed bootstrap script'
grep -Fq "$expected_secret_dir" "$start_source" || fail 'PostgreSQL start wrapper does not pin the secret directory'
grep -Fq "$expected_secret_dir" "$bootstrap_source" || fail 'bootstrap wrapper does not pin the secret directory'
grep -Fq 'eventsales-prod_eventsales_data' "$provision_source" || fail 'network wrapper data network is not fixed'
grep -Fq 'eventsales-prod_eventsales_edge' "$provision_source" || fail 'network wrapper edge network is not fixed'
grep -Fq 'eventsales-prod_postgres_data' "$start_source" || fail 'PostgreSQL volume identity is not fixed'
grep -Fq "EXPECTED_SCRIPT_SHA256='dc22844432d1591bd31abfb7b62595afa373ac13a113dd2a7553633e02813348'" "$provision_source" || fail 'network wrapper does not pin the accepted provisioner bytes'
grep -Fq "EXPECTED_COMPOSE_SHA256='f8d2cee51d6647d7026324ffee8a6ebf82cf8ea7e7a3ed6ca82626cf67b5819f'" "$start_source" || fail 'PostgreSQL wrapper does not pin the accepted Compose bytes'

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/eventsales-v3-wrappers.XXXXXX")
chmod 0755 "$tmp_root"
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

root_run() {
  # The source is transformed below, so use a test-only effective UID instead
  # of relying on user namespaces, which hosted runners may disable.
  EVENTSALES_TEST_EUID=0 "$@"
}

nonroot_run() {
  local wrapper=$1
  EVENTSALES_TEST_EUID=65534 "$wrapper"
}

state_set() {
  local key=$1 value=$2
  /usr/bin/awk -F= -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$fixture/state" >"$fixture/state.tmp"
  /usr/bin/mv -- "$fixture/state.tmp" "$fixture/state"
}

state_reset_networks() {
  state_set NETWORKS ''
  state_set DATA_DRIVER bridge
  state_set DATA_INTERNAL true
  state_set EDGE_DRIVER bridge
  state_set EDGE_INTERNAL false
}

state_set_production_networks() {
  state_set NETWORKS 'eventsales-prod_eventsales_data,eventsales-prod_eventsales_edge'
}

state_reset_container() {
  state_set CONTAINERS ''
  state_set VOLUMES ''
  state_set STATUS running
  state_set HEALTH healthy
  state_set RESTARTS 0
  state_set IMAGE 'dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19'
  state_set MEMORY 3221225472
  state_set NANO_CPUS 2000000000
  state_set CMD_JSON '["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
  state_set PORT_BINDINGS null
  state_set MOUNTS_JSON '[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"}]'
  state_set NETWORKS_JSON '{"eventsales-prod_eventsales_data":{}}'
}

new_fixture() {
  cleanup_fixture
  fixture=$(mktemp -d "$tmp_root/fixture.XXXXXX")
  local stage="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane"
  mkdir -p "$stage/scripts" "$fixture/bin" "$fixture/secrets-v1"
  cp "$repo_root/deploy/vps/data-plane/scripts/provision-networks.sh" "$stage/scripts/provision-networks.sh"
  cp "$repo_root/deploy/vps/data-plane/compose.yaml" "$stage/compose.yaml"
  chmod 0555 "$stage/scripts/provision-networks.sh"
  chmod 0444 "$stage/compose.yaml"

  cat >"$stage/scripts/bootstrap-postgres.sh" <<'CHILD'
#!/bin/bash
printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_0_PREFLIGHT\n'
printf 'CHILD_SECRET_TARGET=%s\n' "$1"
printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_4_PROBE\n'
printf 'POSTGRES_PROBE=PASS\n'
printf 'POSTGRES_BOOTSTRAP_STATE=BOOTSTRAPPED\n'
CHILD
  cat >"$stage/scripts/probe-postgres.sh" <<'CHILD'
#!/bin/bash
printf 'STANDALONE_PROBE_CHILD_EXECUTED\n'
CHILD
  chmod 0555 "$stage/scripts/bootstrap-postgres.sh" "$stage/scripts/probe-postgres.sh"
  local bootstrap_fixture_sha probe_fixture_sha
  bootstrap_fixture_sha=$(/usr/bin/sha256sum "$stage/scripts/bootstrap-postgres.sh" | /usr/bin/awk '{print $1}')
  probe_fixture_sha=$(/usr/bin/sha256sum "$stage/scripts/probe-postgres.sh" | /usr/bin/awk '{print $1}')

  local raw_name
  for raw_name in \
    postgres_bootstrap_password \
    eventsales_migrator_password \
    eventsales_runtime_server_password \
    eventsales_runtime_client_password \
    eventsales_backup_password \
    redis_runtime_password \
    redis_stats_password \
    pgbouncer.ini \
    pgbouncer_users.txt \
    redis-users.acl; do
    /usr/bin/printf '%s' "$secret_sentinel" >"$fixture/secrets-v1/$raw_name"
    /usr/bin/truncate -s 64 "$fixture/secrets-v1/$raw_name"
    if [[ "$raw_name" == postgres_bootstrap_password || "$raw_name" == pgbouncer.ini || "$raw_name" == pgbouncer_users.txt || "$raw_name" == redis-users.acl ]]; then
      chmod 0440 "$fixture/secrets-v1/$raw_name"
    else
      chmod 0400 "$fixture/secrets-v1/$raw_name"
    fi
  done
  chmod 0700 "$fixture/secrets-v1"

  cat >"$fixture/compose.json" <<'JSON'
{
  "name": "eventsales-prod",
  "services": {
    "postgres": {
      "image": "dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19",
      "restart": "unless-stopped",
      "cpus": 2.0,
      "mem_limit": "3g",
      "command": ["postgres", "-c", "max_connections=100", "-c", "shared_buffers=768MB", "-c", "effective_cache_size=2GB", "-c", "work_mem=8MB", "-c", "maintenance_work_mem=256MB"],
      "volumes": [{"type": "volume", "source": "postgres_data", "target": "/var/lib/postgresql"}],
      "networks": ["eventsales_data"],
      "expose": ["5432"],
      "healthcheck": {"test": ["CMD", "pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "postgres"]},
      "secrets": [{"source": "postgres_bootstrap_password", "target": "postgres_bootstrap_password"}]
    },
    "pgbouncer": {"image": "fixture/pgbouncer", "networks": ["eventsales_data"]},
    "redis": {"image": "fixture/redis", "networks": ["eventsales_data"]}
  },
  "networks": {
    "eventsales_data": {"name": "eventsales-prod_eventsales_data", "external": true}
  },
  "volumes": {
    "postgres_data": {"name": "eventsales-prod_postgres_data"}
  },
  "secrets": {
    "postgres_bootstrap_password": {"file": "FIXTURE_SECRET_DIR/postgres_bootstrap_password"},
    "pgbouncer_ini": {"file": "FIXTURE_SECRET_DIR/pgbouncer.ini"},
    "pgbouncer_users": {"file": "FIXTURE_SECRET_DIR/pgbouncer_users.txt"},
    "redis_acl": {"file": "FIXTURE_SECRET_DIR/redis-users.acl"}
  }
}
JSON
  /usr/bin/sed -i "s|FIXTURE_SECRET_DIR|$fixture/secrets-v1|g" "$fixture/compose.json"

  cat >"$fixture/state" <<'STATE'
NETWORKS=
DATA_DRIVER=bridge
DATA_INTERNAL=true
EDGE_DRIVER=bridge
EDGE_INTERNAL=false
VOLUMES=
CONTAINERS=
STATUS=running
HEALTH=healthy
RESTARTS=0
IMAGE=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
MEMORY=3221225472
NANO_CPUS=2000000000
CMD_JSON=["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]
PORT_BINDINGS=null
MOUNTS_JSON=[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"}]
NETWORKS_JSON={"eventsales-prod_eventsales_data":{}}
STATE

  cat >"$fixture/bin/docker" <<'DOCKER'
#!/bin/bash
set -e
state='FIXTURE_STATE'
log='FIXTURE_LOG'
compose_json='FIXTURE_COMPOSE'
printf 'ENV|host=%s|context=%s|path=%s|project=%s|secret=%s|docker_config=%s|compose_file=%s|staged_script=%s|target_path=%s\n' \
  "$DOCKER_HOST" "$DOCKER_CONTEXT" "$PATH" "$COMPOSE_PROJECT_NAME" "$EVENTSALES_SECRET_DIR" "$DOCKER_CONFIG" "$COMPOSE_FILE" "$STAGED_SCRIPT" "$TARGET_PATH" >>"$log"
printf 'CALL|%s\n' "$*" >>"$log"
printf 'ENV_EXTRA|cwd=%s\n' "$(pwd -P)" >>"$log"
get() {
  /usr/bin/awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$state"
}
put() {
  /usr/bin/awk -F= -v key="$1" -v value="$2" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$state" >"$state.tmp"
  /usr/bin/mv -- "$state.tmp" "$state"
}
case "$1:$2" in
  network:ls)
    /usr/bin/tr ',' '\n' < <(get NETWORKS)
    ;;
  network:inspect)
    name=$5
    names=$(get NETWORKS)
    case ",$names," in *",$name,"*) ;; *) exit 1 ;; esac
    if [[ "$name" == eventsales-prod_eventsales_data ]]; then
      printf '%s|%s|%s\n' "$name" "$(get DATA_DRIVER)" "$(get DATA_INTERNAL)"
    else
      printf '%s|%s|%s\n' "$name" "$(get EDGE_DRIVER)" "$(get EDGE_INTERNAL)"
    fi
    ;;
  network:create)
    if [[ "$*" == *'--internal'* ]]; then
      name=$6
      names=$(get NETWORKS)
      [[ -z "$names" ]] && names=$name || names="$names,$name"
      put NETWORKS "$names"
      put DATA_DRIVER bridge
      put DATA_INTERNAL true
    else
      name=$5
      [[ "$(get FAIL_EDGE_CREATE)" != 1 ]] || exit 44
      names=$(get NETWORKS)
      [[ -z "$names" ]] && names=$name || names="$names,$name"
      put NETWORKS "$names"
      put EDGE_DRIVER bridge
      put EDGE_INTERNAL false
    fi
    printf '%s\n' "$name"
    ;;
  volume:ls)
    /usr/bin/tr ',' '\n' < <(get VOLUMES)
    ;;
  volume:inspect)
    name=$5
    volumes=$(get VOLUMES)
    case ",$volumes," in *",$name,"*) printf '%s\n' "$name" ;; *) exit 1 ;; esac
    ;;
  ps:*)
    names=$(get CONTAINERS)
    /usr/bin/tr ',' '\n' <<<"$names"
    ;;
  compose:*)
    [[ "$2" == --project-name && "$3" == eventsales-prod && "$4" == -f ]] || exit 90
    [[ "$5" == FIXTURE_COMPOSE_PATH ]] || exit 91
    if [[ "$6" == config && "$7" == --format && "$8" == json ]]; then
      /usr/bin/cat "$compose_json"
    elif [[ "$6" == up && "$7" == -d && "$8" == postgres && $# == 8 ]]; then
      [[ "$(get UP_FAIL)" != 1 ]] || exit 1
      put VOLUMES eventsales-prod_postgres_data
      put CONTAINERS eventsales-prod-postgres-1
    else
      exit 92
    fi
    ;;
  inspect:*)
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$(get STATUS)" "$(get HEALTH)" "$(get RESTARTS)" "$(get IMAGE)" \
      "$(get MEMORY)" "$(get NANO_CPUS)" "$(get CMD_JSON)" "$(get PORT_BINDINGS)" \
      "$(get MOUNTS_JSON)" "$(get NETWORKS_JSON)"
    ;;
  *)
    exit 93
    ;;
esac
DOCKER
  /usr/bin/sed -i \
    -e "s|FIXTURE_STATE|$fixture/state|g" \
    -e "s|FIXTURE_LOG|$fixture/docker.log|g" \
    -e "s|FIXTURE_COMPOSE_PATH|$stage/compose.yaml|g" \
    -e "s|FIXTURE_COMPOSE|$fixture/compose.json|g" \
    "$fixture/bin/docker"
  chmod 0555 "$fixture/bin/docker"
  mkdir -p "$fixture/attacker-bin"
  cat >"$fixture/attacker-bin/docker" <<'ATTACKER'
#!/bin/sh
printf 'ATTACKER_DOCKER_RAN\n' >'FIXTURE_ATTACKER_LOG'
exit 111
ATTACKER
  /usr/bin/sed -i "s|FIXTURE_ATTACKER_LOG|$fixture/attacker.log|g" "$fixture/attacker-bin/docker"
  chmod 0555 "$fixture/attacker-bin/docker"
  cat >"$fixture/bin/sleep" <<'SLEEP'
#!/bin/sh
exit 0
SLEEP
  chmod 0555 "$fixture/bin/sleep"

  sed \
    -e "s|/root/eventsales-prod|$fixture|g" \
    -e "s|'/root'|'$fixture'|g" \
    -e "s|/usr/sbin:/usr/bin:/sbin:/bin|$fixture/bin:/usr/sbin:/usr/bin:/sbin:/bin|g" \
    -e 's|postgres_bootstrap_password 0 70 440 64|postgres_bootstrap_password 0 0 440 64|g' \
    -e 's| 0 65532 440| 0 0 440|g' \
    -e 's|EUID != 0|EVENTSALES_TEST_EUID != 0|g' \
    -e "s|owner\" == 0|owner\" == $fixture_uid|g" \
    -e "s|group\" == 0|group\" == $fixture_gid|g" \
    -e "s|0:0:700|$fixture_uid:$fixture_gid:700|g" \
    -e "s|postgres_bootstrap_password 0 0 440 64|postgres_bootstrap_password $fixture_uid $fixture_gid 440 64|g" \
    -e "s| 0 0 400| $fixture_uid $fixture_gid 400|g" \
    -e "s| 0 0 440| $fixture_uid $fixture_gid 440|g" \
    "$provision_source" >"$fixture/provision-wrapper"
  sed \
    -e "s|/root/eventsales-prod|$fixture|g" \
    -e "s|'/root'|'$fixture'|g" \
    -e "s|/usr/sbin:/usr/bin:/sbin:/bin|$fixture/bin:/usr/sbin:/usr/bin:/sbin:/bin|g" \
    -e 's|postgres_bootstrap_password 0 70 440 64|postgres_bootstrap_password 0 0 440 64|g' \
    -e 's| 0 65532 440| 0 0 440|g' \
    -e 's|EUID != 0|EVENTSALES_TEST_EUID != 0|g' \
    -e "s|owner\" == 0|owner\" == $fixture_uid|g" \
    -e "s|group\" == 0|group\" == $fixture_gid|g" \
    -e "s|0:0:700|$fixture_uid:$fixture_gid:700|g" \
    -e "s|postgres_bootstrap_password 0 0 440 64|postgres_bootstrap_password $fixture_uid $fixture_gid 440 64|g" \
    -e "s| 0 0 400| $fixture_uid $fixture_gid 400|g" \
    -e "s| 0 0 440| $fixture_uid $fixture_gid 440|g" \
    "$start_source" >"$fixture/start-wrapper"
  sed \
    -e "s|/root/eventsales-prod|$fixture|g" \
    -e "s|'/root'|'$fixture'|g" \
    -e "s|/usr/sbin:/usr/bin:/sbin:/bin|$fixture/bin:/usr/sbin:/usr/bin:/sbin:/bin|g" \
    -e "s|afa7c663abd06ec109bbb9172f2d5391fa856e3dfbff1a1f90da29a46265fa7f|$bootstrap_fixture_sha|g" \
    -e "s|3019e4560946957e27f3fca033c754dda1cf9a66adebd61a46208d87b24e77ce|$probe_fixture_sha|g" \
    -e 's|postgres_bootstrap_password 0 70 440 64|postgres_bootstrap_password 0 0 440 64|g' \
    -e 's| 0 65532 440| 0 0 440|g' \
    -e 's|EUID != 0|EVENTSALES_TEST_EUID != 0|g' \
    -e "s|owner\" == 0|owner\" == $fixture_uid|g" \
    -e "s|group\" == 0|group\" == $fixture_gid|g" \
    -e "s|0:0:700|$fixture_uid:$fixture_gid:700|g" \
    -e "s|postgres_bootstrap_password 0 0 440 64|postgres_bootstrap_password $fixture_uid $fixture_gid 440 64|g" \
    -e "s| 0 0 400| $fixture_uid $fixture_gid 400|g" \
    -e "s| 0 0 440| $fixture_uid $fixture_gid 440|g" \
    "$bootstrap_source" >"$fixture/bootstrap-wrapper"
  chmod 0555 "$fixture/provision-wrapper" "$fixture/start-wrapper" "$fixture/bootstrap-wrapper"
  chmod 0755 "$fixture" "$fixture/staged" \
    "$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f" \
    "$stage" "$stage/scripts" "$fixture/bin"
}

expect_rejection() {
  local name=$1 wrapper=$2 expected=$3 output status
  shift 3
  if output=$(root_run "$wrapper" "$@" 2>&1); then
    fail "$name unexpectedly succeeded"
  else
    status=$?
  fi
  (( status != 0 )) || fail "$name returned success"
  [[ "$output" == *"STOP=$expected"* ]] || fail "$name returned the wrong safe stop code"
  [[ "$output" != *"$secret_sentinel"* ]] || fail "$name exposed fixture secret contents"
  pass "$name"
}

expect_nonroot_rejection() {
  local name=$1 wrapper=$2 output status
  if output=$(nonroot_run "$wrapper" 2>&1); then
    fail "$name unexpectedly succeeded"
  else
    status=$?
  fi
  (( status != 0 )) || fail "$name returned success"
  [[ "$output" == *'STOP=ROOT_REQUIRED'* ]] || fail "$name did not stop at the root boundary"
  pass "$name"
}

expect_clean_output() {
  local name=$1 output=$2
  [[ "$output" != *"$secret_sentinel"* ]] || fail "$name exposed fixture secret contents"
  pass "$name"
}

new_fixture
expect_rejection 'network wrapper rejects arguments' "$fixture/provision-wrapper" CALLER_ARGUMENTS_FORBIDDEN extra
expect_rejection 'PostgreSQL wrapper rejects arguments' "$fixture/start-wrapper" CALLER_ARGUMENTS_FORBIDDEN extra
expect_rejection 'bootstrap wrapper rejects arguments' "$fixture/bootstrap-wrapper" CALLER_ARGUMENTS_FORBIDDEN extra
expect_nonroot_rejection 'network wrapper requires root' "$fixture/provision-wrapper"
expect_nonroot_rejection 'PostgreSQL wrapper requires root' "$fixture/start-wrapper"
expect_nonroot_rejection 'bootstrap wrapper requires root' "$fixture/bootstrap-wrapper"

new_fixture
state_set_production_networks
expect_rejection 'network wrapper rejects a pre-existing first-provision network' "$fixture/provision-wrapper" FIRST_PROVISION_NETWORK_PRESENT

new_fixture
state_reset_networks
state_set VOLUMES eventsales-prod_postgres_data
expect_rejection 'network wrapper rejects a pre-existing production volume' "$fixture/provision-wrapper" FIRST_PROVISION_VOLUME_PRESENT

new_fixture
state_reset_networks
state_set CONTAINERS eventsales-prod-postgres-1
expect_rejection 'network wrapper rejects existing production containers' "$fixture/provision-wrapper" FIRST_PROVISION_CONTAINER_PRESENT

new_fixture
state_reset_networks
chmod 0775 "$fixture/staged"
expect_rejection 'network wrapper rejects an unsafe staged ancestor' "$fixture/provision-wrapper" STAGED_DIRECTORY_GROUP_OR_OTHER_WRITABLE

new_fixture
state_reset_networks
chmod 0775 "$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts/provision-networks.sh"
expect_rejection 'network wrapper rejects a writable staged child' "$fixture/provision-wrapper" STAGED_SCRIPT_WRITABLE

new_fixture
state_reset_networks
stage="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane"
mv "$stage/scripts/provision-networks.sh" "$stage/scripts/provision-networks.real"
ln -s provision-networks.real "$stage/scripts/provision-networks.sh"
expect_rejection 'network wrapper rejects a staged child symlink' "$fixture/provision-wrapper" STAGED_SCRIPT_SYMLINK

new_fixture
state_reset_networks
output=$(root_run "$fixture/provision-wrapper" 2>&1) || fail 'network wrapper failed against fixture Docker'
[[ "$output" == *'NETWORK_NAME=eventsales-prod_eventsales_data DRIVER=bridge INTERNAL=true STATE=created'* ]] || fail 'network wrapper did not run the accepted first-provision child'
[[ "$output" == *'NETWORK_NAME=eventsales-prod_eventsales_edge DRIVER=bridge INTERNAL=false STATE=created'* ]] || fail 'network wrapper did not create the accepted edge network'
grep -Fq 'CALL|network create --driver bridge --internal eventsales-prod_eventsales_data' "$fixture/docker.log" || fail 'network creation did not use the accepted data network identity'
grep -Fq 'CALL|network create --driver bridge eventsales-prod_eventsales_edge' "$fixture/docker.log" || fail 'network creation did not use the accepted edge network identity'
pass 'network wrapper invokes only the accepted provisioner and preserves exact network settings'

new_fixture
state_reset_networks
state_set FAIL_EDGE_CREATE 1
if output=$(root_run "$fixture/provision-wrapper" 2>&1); then
  fail 'network provision wrapper hid the accepted child failure'
fi
[[ "$output" == *'STOP=NETWORK_CREATE_FAILED name=eventsales-prod_eventsales_edge'* ]] || fail 'network wrapper discarded partial-state evidence'
[[ "$(awk -F= '$1 == "NETWORKS" {print $2}' "$fixture/state")" == eventsales-prod_eventsales_data ]] || fail 'network wrapper rolled back partial network state'
! grep -Eq 'network rm|volume rm|container rm| compose down' "$fixture/docker.log" || fail 'network wrapper attempted rollback or repair'
pass 'network failure preserves partial state and does not roll back'

new_fixture
state_reset_networks
output=$(root_run /usr/bin/env \
  DOCKER_HOST=tcp://attacker.invalid:2375 \
  DOCKER_CONTEXT=attacker \
  PATH="$fixture/attacker-bin" \
  COMPOSE_PROJECT_NAME=attacker \
  COMPOSE_FILE="$fixture/attacker-compose.yaml" \
  STAGED_SCRIPT="$fixture/attacker-script" \
  SCRIPT_PATH="$fixture/attacker-script" \
  TARGET_PATH="$fixture/attacker-target" \
  DOCKER_CONFIG="$fixture/attacker-docker-config" \
  EVENTSALES_SECRET_DIR="$fixture/attacker-secrets" \
  "$fixture/provision-wrapper" 2>&1) || fail 'network wrapper did not survive hostile caller environment'
grep -Fq 'host=unix:///var/run/docker.sock|context=|path=' "$fixture/docker.log" || fail 'network child did not receive the fixed local socket and sanitized environment'
! grep -Fq 'attacker' "$fixture/docker.log" || fail 'network wrapper retained caller-controlled Docker or path settings'
[[ ! -e "$fixture/attacker.log" ]] || fail 'network wrapper invoked a caller-controlled Docker executable'
grep -Fq 'ENV_EXTRA|cwd=/' "$fixture/docker.log" || fail 'network wrapper retained the caller working directory'
expect_clean_output 'network environment redirection test' "$output"

new_fixture
state_set_production_networks
state_reset_container
output=$(root_run /usr/bin/env \
  DOCKER_HOST=tcp://attacker.invalid:2375 \
  DOCKER_CONTEXT=attacker \
  PATH="$fixture/attacker-bin" \
  COMPOSE_PROJECT_NAME=attacker \
  COMPOSE_FILE="$fixture/attacker-compose.yaml" \
  STAGED_SCRIPT="$fixture/attacker-script" \
  SCRIPT_PATH="$fixture/attacker-script" \
  TARGET_PATH="$fixture/attacker-target" \
  DOCKER_CONFIG="$fixture/attacker-docker-config" \
  EVENTSALES_SECRET_DIR="$fixture/attacker-secrets" \
  "$fixture/start-wrapper" 2>&1) || fail 'PostgreSQL start wrapper failed against healthy fake Docker'
grep -Fq 'CALL|compose --project-name eventsales-prod -f ' "$fixture/docker.log" || fail 'PostgreSQL start did not pin the Compose project'
grep -Fq 'up -d postgres' "$fixture/docker.log" || fail 'PostgreSQL start did not request only postgres'
! grep -Eq 'up .*pgbouncer|up .*redis| compose .* pgbouncer| compose .* redis' "$fixture/docker.log" || fail 'PostgreSQL start requested PgBouncer or Redis'
[[ "$(awk -F= '$1 == "CONTAINERS" {print $2}' "$fixture/state")" == eventsales-prod-postgres-1 ]] || fail 'PostgreSQL start created an unexpected service container'
grep -Fq "secret=$fixture/secrets-v1" "$fixture/docker.log" || fail 'PostgreSQL start did not force its fixed secret directory'
grep -Fq 'host=unix:///var/run/docker.sock|context=|path=' "$fixture/docker.log" || fail 'PostgreSQL start did not force the local Docker socket'
! grep -Fq 'attacker' "$fixture/docker.log" || fail 'PostgreSQL start retained caller-controlled paths or Docker environment'
[[ ! -e "$fixture/attacker.log" ]] || fail 'PostgreSQL start invoked a caller-controlled Docker executable'
grep -Fq 'ENV_EXTRA|cwd=/' "$fixture/docker.log" || fail 'PostgreSQL start retained the caller working directory'
expect_clean_output 'PostgreSQL start output safety' "$output"
pass 'PostgreSQL start requests only the fixed postgres service and verifies its healthy contract'

new_fixture
state_reset_networks
expect_rejection 'PostgreSQL start rejects missing production networks' "$fixture/start-wrapper" NETWORK_NOT_PRESENT

new_fixture
state_set_production_networks
state_set DATA_INTERNAL false
state_reset_container
expect_rejection 'PostgreSQL start rejects wrong network settings' "$fixture/start-wrapper" NETWORK_METADATA_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
state_set VOLUMES eventsales-prod_postgres_data
expect_rejection 'PostgreSQL start rejects a pre-existing volume' "$fixture/start-wrapper" FIRST_START_VOLUME_PRESENT

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1
expect_rejection 'PostgreSQL start rejects existing project containers' "$fixture/start-wrapper" PRODUCTION_CONTAINER_PRESENT

new_fixture
state_set_production_networks
state_reset_container
state_set HEALTH unhealthy
expect_rejection 'PostgreSQL start rejects failed health' "$fixture/start-wrapper" POSTGRES_HEALTH_FAILED
[[ $(grep -Ec '^CALL\|compose .* up -d postgres$' "$fixture/docker.log") -eq 1 ]] || fail 'PostgreSQL health failure caused a retry'
pass 'PostgreSQL health failure is terminal and does not restart or recreate'

new_fixture
state_set_production_networks
state_reset_container
state_set RESTARTS 1
expect_rejection 'PostgreSQL start rejects a restart' "$fixture/start-wrapper" POSTGRES_RESTART_COUNT_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
state_set IMAGE wrong-image
expect_rejection 'PostgreSQL start rejects a wrong image' "$fixture/start-wrapper" POSTGRES_IMAGE_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
state_set MEMORY 1024
expect_rejection 'PostgreSQL start rejects a wrong memory envelope' "$fixture/start-wrapper" POSTGRES_RESOURCE_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
state_set PORT_BINDINGS '{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5432"}]}'
expect_rejection 'PostgreSQL start rejects a published host port' "$fixture/start-wrapper" POSTGRES_RUNTIME_CONTRACT_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
stage="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane"
mv "$stage/compose.yaml" "$stage/compose.real"
ln -s compose.real "$stage/compose.yaml"
expect_rejection 'PostgreSQL start rejects a Compose symlink' "$fixture/start-wrapper" STAGED_COMPOSE_SYMLINK

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1
state_set VOLUMES eventsales-prod_postgres_data
if output=$(root_run /usr/bin/env \
  DOCKER_HOST=tcp://attacker.invalid:2375 \
  DOCKER_CONTEXT=attacker \
  PATH="$fixture/attacker-bin" \
  COMPOSE_PROJECT_NAME=attacker \
  COMPOSE_FILE="$fixture/attacker-compose.yaml" \
  STAGED_SCRIPT="$fixture/attacker-script" \
  SCRIPT_PATH="$fixture/attacker-script" \
  TARGET_PATH="$fixture/attacker-target" \
  DOCKER_CONFIG="$fixture/attacker-docker-config" \
  EVENTSALES_SECRET_DIR="$fixture/attacker-secrets" \
  "$fixture/bootstrap-wrapper" 2>&1); then
  :
else
  printf '%s\n' "$output" | /usr/bin/grep '^STOP=' >&2 || true
  fail 'bootstrap wrapper failed against healthy fake Docker'
fi
[[ "$output" == *"CHILD_SECRET_TARGET=$fixture/secrets-v1"* ]] || fail 'bootstrap wrapper did not pass its fixed secret directory'
[[ "$output" == *'POSTGRES_BOOTSTRAP_PHASE=PHASE_4_PROBE'* && "$output" == *'POSTGRES_PROBE=PASS'* ]] || fail 'bootstrap wrapper did not preserve embedded probe evidence'
[[ "$output" == *'POSTGRES_BOOTSTRAP_STATE=BOOTSTRAPPED'* ]] || fail 'bootstrap wrapper discarded the accepted bootstrap result'
[[ "$output" != *'STANDALONE_PROBE_CHILD_EXECUTED'* ]] || fail 'bootstrap wrapper invoked a duplicate standalone probe'
[[ $(printf '%s\n' "$output" | /usr/bin/grep -c '^POSTGRES_BOOTSTRAP_PHASE=PHASE_0_PREFLIGHT$') -eq 1 ]] || fail 'bootstrap wrapper invoked its one-shot child more than once'
grep -Fq "secret=$fixture/secrets-v1" "$fixture/docker.log" || fail 'bootstrap preflight did not use the fixed secret directory'
! grep -Fq 'attacker' "$fixture/docker.log" || fail 'bootstrap retained caller-controlled environment'
[[ ! -e "$fixture/attacker.log" ]] || fail 'bootstrap invoked a caller-controlled Docker executable'
grep -Fq 'ENV_EXTRA|cwd=/' "$fixture/docker.log" || fail 'bootstrap retained the caller working directory'
expect_clean_output 'bootstrap output safety' "$output"
pass 'bootstrap invokes one fixed child, preserves phase markers, and does not run a standalone probe'

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1
state_set VOLUMES eventsales-prod_postgres_data
stage="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane"
chmod 0755 "$stage/scripts/bootstrap-postgres.sh"
cat >"$stage/scripts/bootstrap-postgres.sh" <<'CHILD'
#!/bin/bash
printf 'POSTGRES_BOOTSTRAP_PHASE=PHASE_2_DATABASE\n'
exit 42
CHILD
chmod 0555 "$stage/scripts/bootstrap-postgres.sh"
bootstrap_fixture_sha=$(/usr/bin/sha256sum "$stage/scripts/bootstrap-postgres.sh" | /usr/bin/awk '{print $1}')
/usr/bin/sed -i -E "s|EXPECTED_BOOTSTRAP_SHA256='[a-f0-9]{64}'|EXPECTED_BOOTSTRAP_SHA256='$bootstrap_fixture_sha'|" "$fixture/bootstrap-wrapper"
if output=$(root_run "$fixture/bootstrap-wrapper" 2>&1); then
  fail 'bootstrap wrapper hid a one-shot child failure'
fi
[[ "$output" == *'POSTGRES_BOOTSTRAP_PHASE=PHASE_2_DATABASE'* ]] || fail 'bootstrap wrapper discarded partial phase evidence'
[[ $(printf '%s\n' "$output" | /usr/bin/grep -c '^POSTGRES_BOOTSTRAP_PHASE=PHASE_2_DATABASE$') -eq 1 ]] || fail 'bootstrap wrapper retried after a child failure'
[[ "$output" != *"$secret_sentinel"* ]] || fail 'bootstrap failure exposed fixture secret contents'
pass 'bootstrap failure preserves its phase evidence and is not retried'

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1
state_set VOLUMES eventsales-prod_postgres_data
state_set HEALTH starting
expect_rejection 'bootstrap rejects unhealthy PostgreSQL' "$fixture/bootstrap-wrapper" POSTGRES_NOT_HEALTHY

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1,eventsales-prod-pgbouncer-1
state_set VOLUMES eventsales-prod_postgres_data
expect_rejection 'bootstrap rejects a started PgBouncer container' "$fixture/bootstrap-wrapper" UNEXPECTED_SERVICE_CONTAINER

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1,eventsales-prod-redis-1
state_set VOLUMES eventsales-prod_postgres_data
expect_rejection 'bootstrap rejects a started Redis container' "$fixture/bootstrap-wrapper" UNEXPECTED_SERVICE_CONTAINER

new_fixture
state_set_production_networks
state_reset_container
state_set DATA_INTERNAL false
state_set CONTAINERS eventsales-prod-postgres-1
state_set VOLUMES eventsales-prod_postgres_data
expect_rejection 'bootstrap rejects a wrong data network contract' "$fixture/bootstrap-wrapper" DATA_NETWORK_METADATA_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1
state_set VOLUMES eventsales-prod_postgres_data
state_set IMAGE wrong-image
expect_rejection 'bootstrap rejects an unexpected PostgreSQL image' "$fixture/bootstrap-wrapper" POSTGRES_IMAGE_MISMATCH

new_fixture
state_set_production_networks
state_reset_container
state_set CONTAINERS eventsales-prod-postgres-1
state_set VOLUMES eventsales-prod_postgres_data
stage="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane"
mv "$stage/scripts/bootstrap-postgres.sh" "$stage/scripts/bootstrap.real"
ln -s bootstrap.real "$stage/scripts/bootstrap-postgres.sh"
expect_rejection 'bootstrap rejects a staged script symlink' "$fixture/bootstrap-wrapper" STAGED_SCRIPT_SYMLINK

expected_sudoers='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-provision-networks "", /usr/local/sbin/agent-eventsales-v3-start-postgres "", /usr/local/sbin/agent-eventsales-v3-bootstrap-postgres ""'
[[ "$(cat -- "$sudoers_source")" == "$expected_sudoers" ]] || fail 'sudoers does not grant exactly the three zero-argument wrappers'
[[ $(wc -l <"$sudoers_source") -eq 1 ]] || fail 'sudoers contains extra rules or lines'
! grep -Eiq 'ALL[[:space:]]*$|/bin/(ba)?sh|docker|\*' "$sudoers_source" || fail 'sudoers contains generic Docker, shell, wildcard, or ALL authority'
/usr/sbin/visudo -cf "$sudoers_source" >/dev/null || fail 'VPS-native visudo rejected the V3 sudoers fragment'
pass 'sudoers grants exactly three no-argument wrappers and passes visudo'

awk '
  /^  vps_deploy_contract:/ { in_job = 1; next }
  in_job && /^  [a-zA-Z0-9_-]+:/ { in_job = 0 }
  in_job && /name: Verify EventSales V3 privileged wrappers/ { named = 1 }
  in_job && /bash test\/scripts\/agent_eventsales_v3_wrappers_test.sh/ { invoked = 1 }
  END { if (named && invoked) exit 0; exit 1 }
' "$repo_root/.github/workflows/ci.yml" || fail 'V3 wrapper regression suite is not in the existing vps_deploy_contract job'
pass 'CI runs the V3 wrapper suite inside the existing deployment-contract job'

printf 'RESULT=PASS\nTESTS_PASSED=%s\n' "$passes"
