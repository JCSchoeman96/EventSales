#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
wrapper_source="$repo_root/deploy/vps/operator/agent-eventsales-v4-start-data-plane"
sudoers_source="$repo_root/deploy/vps/operator/agent-eventsales-v4-start-data-plane.sudoers"
compose_source="$repo_root/deploy/vps/data-plane/compose.yaml"
fixture_uid=$(id -u)
fixture_gid=$(id -g)
passes=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }

[[ -f "$compose_source" && ! -L "$compose_source" ]] || fail 'data-plane Compose source is missing'

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/eventsales-v4-start.XXXXXX")
fixture="$tmp_root/fixture"
root_fixture="$fixture/root"
fixture_bin="$fixture/bin"
secret_fixture="$root_fixture/eventsales-prod/secrets-v1"
stage_fixture="$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane"
volume_fixture="$fixture/volume-one"
volume_alt_fixture="$fixture/volume-two"
state_file="$fixture/state"
docker_log="$fixture/docker.log"
out="$fixture/stdout"
err="$fixture/stderr"
wrapper_fixture="$tmp_root/start-data-plane"
hostile_bash_env="$fixture/hostile-bash-env"
pg_id=$(printf 'a%.0s' {1..64})
pgbouncer_id=$(printf 'b%.0s' {1..64})
redis_id=$(printf 'c%.0s' {1..64})
d0_one=$(printf '1%.0s' {1..64})
d0_two=$(printf '2%.0s' {1..64})
d0_three=$(printf '3%.0s' {1..64})
data_network_id=$(printf '4%.0s' {1..64})
edge_network_id=$(printf '5%.0s' {1..64})

cleanup() { chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf -- "$tmp_root"; }
trap cleanup EXIT
mkdir -p "$fixture_bin"

write_state() {
  cat >"$state_file" <<STATE
PG_PRESENT=yes
PG_ID=$pg_id
PG_STATUS=running
PG_RUNNING=true
PG_RESTARTING=false
PG_HEALTH=healthy
PG_RESTARTS=0
PG_OOM=false
PG_IMAGE=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
PG_MEMORY=3221225472
PG_NANO=2000000000
PG_CAPDROP=[]
PG_SECURITY=[]
PG_TMPFS={}
PG_CAPDROP_KEY=PRESENT
PG_SECURITY_KEY=PRESENT
PG_TMPFS_KEY=PRESENT
PG_MOUNTS=valid
PG_NETWORKS=valid
PG_PORTS={}
PG_PORTBINDINGS_KEY=PRESENT
PG_COMMAND=valid
PROJECT_ROWS=$pg_id|eventsales-prod-postgres-1
NAME_ROWS=$pg_id|eventsales-prod-postgres-1
APP_PROJECT_ROWS=
APP_NAME_ROWS=
PGB_PRESENT=no
PGB_ID=$pgbouncer_id
PGB_NAME=eventsales-prod-pgbouncer-1
PGB_STATUS=running
PGB_RUNNING=true
PGB_RESTARTING=false
PGB_HEALTH=healthy
PGB_RESTARTS=0
PGB_OOM=false
PGB_IMAGE=ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:965b0223f1096666471e11595f4f6dc5d32dfacbc688418b8ae2385946c41e3b
PGB_MEMORY=134217728
PGB_NANO=500000000
PGB_USER=65532:65532
PGB_READONLY=true
PGB_CAPDROP=["ALL"]
PGB_SECURITY=["no-new-privileges:true"]
PGB_TMPFS={"/tmp":"rw,noexec,nosuid,size=16m,mode=1777"}
PGB_CAPDROP_KEY=PRESENT
PGB_SECURITY_KEY=PRESENT
PGB_TMPFS_KEY=PRESENT
PGB_MOUNTS=valid
PGB_NETWORKS=valid
PGB_PORTS={}
PGB_PORTBINDINGS_KEY=PRESENT
PGB_COMMAND=[]
REDIS_PRESENT=no
REDIS_ID=$redis_id
REDIS_NAME=eventsales-prod-redis-1
REDIS_STATUS=running
REDIS_RUNNING=true
REDIS_RESTARTING=false
REDIS_HEALTH=healthy
REDIS_RESTARTS=0
REDIS_OOM=false
REDIS_IMAGE=dhi.io/redis:8.10.2-debian13@sha256:953ca2c2ab4ff7a93f8abac31339ba4d913ec0914861453ab4faa29d154115a0
REDIS_MEMORY=536870912
REDIS_NANO=500000000
REDIS_USER=65532:65532
REDIS_READONLY=true
REDIS_CAPDROP=["ALL"]
REDIS_SECURITY=["no-new-privileges:true"]
REDIS_TMPFS={}
REDIS_CAPDROP_KEY=PRESENT
REDIS_SECURITY_KEY=PRESENT
REDIS_TMPFS_KEY=PRESENT
REDIS_MOUNTS=valid
REDIS_NETWORKS=valid
REDIS_PORTS={}
REDIS_PORTBINDINGS_KEY=PRESENT
REDIS_COMMAND=valid
D0_ROWS=$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1,$d0_three|eventsales-d0-proof-redis-1
D0_PROJECT_ROWS=$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1,$d0_three|eventsales-d0-proof-redis-1
D0_NAME_ROWS=$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1,$d0_three|eventsales-d0-proof-redis-1
D0_STATUS=exited
D0_RUNNING=false
D0_RESTARTING=false
D0_INSPECT_COUNT=0
D0_DRIFT_BEFORE_MARKER=none
DATA_NETWORK_DRIVER=bridge
DATA_NETWORK_INTERNAL=true
DATA_NETWORK_ID=$data_network_id
EDGE_NETWORK_DRIVER=bridge
EDGE_NETWORK_INTERNAL=false
EDGE_NETWORK_ID=$edge_network_id
VOLUME_PRESENT=yes
VOLUME_NAME=eventsales-prod_postgres_data
VOLUME_DRIVER=local
VOLUME_SCOPE=local
VOLUME_PATH=$volume_fixture
PG_VOLUME_SOURCE=$volume_fixture
ATTACHED_DATA_NETWORK_ID=$data_network_id
ATTACHED_EDGE_NETWORK_ID=$edge_network_id
COMPOSE_STATUS=0
COMPOSE_CREATE=both
COMPOSE_EXTRA=no
COMPOSE_UNLABELED=no
COMPOSE_APP=no
COMPOSE_PG_DRIFT=none
COMPOSE_D0_DRIFT=none
COMPOSE_NETWORK_DRIFT=no
COMPOSE_VOLUME_DRIFT=no
COMPOSE_HEALTH=healthy
COMPOSE_HEALTH_AFTER=0
HEALTH_INSPECT_COUNT=0
RESTART_AFTER_INSPECT=0
CREATE_MARKER_FAIL=no
META_OVERRIDE_TARGET=none
META_OVERRIDE_VALUE=none
STATE
  : >"$docker_log"
}

get_state() { /usr/bin/awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$state_file"; }
set_state() {
  local key=$1 value=$2
  /usr/bin/awk -F= -v key="$key" -v value="$value" 'BEGIN{found=0} $1==key{print key "=" value;found=1;next}{print} END{if(!found)print key "=" value}' "$state_file" >"$state_file.tmp"
  /usr/bin/mv -- "$state_file.tmp" "$state_file"
}

make_filesystem() {
  chmod -R u+w "$root_fixture" 2>/dev/null || true
  rm -rf -- "$root_fixture" "$volume_fixture" "$volume_alt_fixture"
  mkdir -p "$stage_fixture" "$secret_fixture" "$volume_fixture" "$volume_alt_fixture" "$fixture_bin"
  cp -- "$compose_source" "$stage_fixture/compose.yaml"
  chmod 0444 "$stage_fixture/compose.yaml"
  for name in eventsales_runtime_server_password eventsales_runtime_client_password redis_runtime_password redis_stats_password; do
    head -c 64 /dev/zero >"$secret_fixture/$name"
    chmod 0400 "$secret_fixture/$name"
  done
  for name in pgbouncer.ini pgbouncer_users.txt redis-users.acl; do
    printf 'safe fixture\n' >"$secret_fixture/$name"
    chmod 0440 "$secret_fixture/$name"
  done
  chmod 0700 "$secret_fixture"
  mkdir -m 0700 "$root_fixture/eventsales-prod/.v3-postgres-recovery-consumed"
  mkdir -m 0700 "$root_fixture/eventsales-prod/.v3-postgres-bootstrap-v2-consumed"
  chmod 0755 "$root_fixture" "$root_fixture/eventsales-prod" \
    "$root_fixture/eventsales-prod/staged"
  chmod 0555 "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107"
  chmod 0555 "$stage_fixture"
}

cat >"$fixture_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
log='FIXTURE_LOG'
get() { /usr/bin/awk -F= -v key="$1" '$1==key{sub(/^[^=]*=/," ");sub(/^ /,"");print;exit}' "$state"; }
setv() { /usr/bin/awk -F= -v key="$1" -v value="$2" 'BEGIN{f=0}$1==key{print key "=" value;f=1;next}{print}END{if(!f)print key "=" value}' "$state" >"$state.tmp"; /usr/bin/mv "$state.tmp" "$state"; }
printf 'ENV|host=%s|context=%s|config=%s|path=%s|project=%s|secret=%s|compose_file=%s|bash_env=%s\n' \
  "${DOCKER_HOST-}" "${DOCKER_CONTEXT-}" "${DOCKER_CONFIG-}" "${PATH-}" "${COMPOSE_PROJECT_NAME-}" \
  "${EVENTSALES_SECRET_DIR-}" "${COMPOSE_FILE-}" "${BASH_ENV-}" >>"$log"
printf 'CALL|%s\n' "$*" >>"$log"
command=${1-}
case "$command" in
  ps)
    filter=
    while (($#)); do
      case "$1" in --filter) filter=${2-}; shift 2 ;; *) shift ;; esac
    done
    case "$filter" in
      label=com.docker.compose.project=eventsales-prod) value=$(get PROJECT_ROWS) ;;
      name=eventsales-prod) value=$(get NAME_ROWS) ;;
      label=com.docker.compose.project=eventsales-app) value=$(get APP_PROJECT_ROWS) ;;
      name=eventsales-app) value=$(get APP_NAME_ROWS) ;;
      label=com.docker.compose.project=eventsales-d0-proof) value=$(get D0_PROJECT_ROWS) ;;
      name=eventsales-d0-proof) value=$(get D0_NAME_ROWS) ;;
      *) exit 80 ;;
    esac
    [[ -z "$value" ]] || /usr/bin/tr ',' '\n' <<<"$value"
    ;;
  inspect)
    format=${3-}
    id=${4-}
    if [[ "$format" == *'{{.State.Restarting}}'* && "$format" != *'{{json .Config.Cmd}}'* ]]; then
      rows=$(get D0_ROWS)
      found=no
      IFS=',' read -r -a d0_items <<<"$rows"
      for item in "${d0_items[@]}"; do
        IFS='|' read -r d0_id d0_name <<<"$item"
        if [[ "$id" == "$d0_id" ]]; then
          printf '%s|/%s|%s|%s|%s\n' "$id" "$d0_name" "$(get D0_STATUS)" "$(get D0_RUNNING)" "$(get D0_RESTARTING)"
          found=yes
        fi
      done
      [[ "$found" == yes ]] || exit 1
      inspect_count=$(( $(get D0_INSPECT_COUNT) + 1 ))
      setv D0_INSPECT_COUNT "$inspect_count"
      if [[ "$inspect_count" -eq 3 ]]; then
        case "$(get D0_DRIFT_BEFORE_MARKER)" in
          identity)
            rows="$(printf '6%.0s' {1..64})|eventsales-d0-proof-postgres-1,$(get D0_PROJECT_ROWS | cut -d, -f2-)"
            setv D0_PROJECT_ROWS "$rows"
            setv D0_NAME_ROWS "$rows"
            setv D0_ROWS "$rows"
            ;;
        esac
      fi
      exit 0
    fi
    if [[ "$format" == *'{{json .Config.Cmd}}'* ]]; then
      prefix=
      if [[ "$id" == "$(get PG_ID)" && "$(get PG_PRESENT)" == yes ]]; then prefix=PG
      elif [[ "$id" == "$(get PGB_ID)" && "$(get PGB_PRESENT)" == yes ]]; then prefix=PGB
      elif [[ "$id" == "$(get REDIS_ID)" && "$(get REDIS_PRESENT)" == yes ]]; then prefix=REDIS
      fi
      [[ -n "$prefix" ]] || exit 1
      capdrop=$(get "${prefix}_CAPDROP")
      security=$(get "${prefix}_SECURITY")
      tmpfs=$(get "${prefix}_TMPFS")
      ports=$(get "${prefix}_PORTS")
      for field in CapDrop SecurityOpt Tmpfs PortBindings; do
        case "$field" in
          CapDrop) suffix=CAPDROP ;;
          SecurityOpt) suffix=SECURITY ;;
          Tmpfs) suffix=TMPFS ;;
          PortBindings) suffix=PORTBINDINGS ;;
        esac
        key_state=$(get "${prefix}_${suffix}_KEY")
        [[ "$key_state" != ABSENT ]] || {
          direct="{{json .HostConfig.$field}}"
          if [[ "$format" == *"$direct"* ]]; then
            printf 'TEMPLATE_ERROR|%s|%s|missing-key\n' "$prefix" "$field" >>"$log"
            printf 'template parsing error: template: :1:374: executing "" at <.HostConfig.%s>: map has no entry for key "%s"\n' \
              "$field" "$field" >&2
            exit 1
          fi
          [[ "$format" == *"index .HostConfig \"$field\""* ]] || exit 87
          case "$field" in
            CapDrop) capdrop='[]' ;;
            SecurityOpt) security='[]' ;;
            Tmpfs|PortBindings) [[ "$field" != Tmpfs ]] || tmpfs='{}'; [[ "$field" != PortBindings ]] || ports='{}' ;;
          esac
        }
      done
      printf 'HOSTCONFIG|%s|CapDrop=%s|SecurityOpt=%s|Tmpfs=%s|PortBindings=%s\n' \
        "$prefix" "$capdrop" "$security" "$tmpfs" "$ports" >>"$log"
      if [[ "$prefix" != PG ]]; then
        count=$(( $(get HEALTH_INSPECT_COUNT) + 1 ))
        setv HEALTH_INSPECT_COUNT "$count"
        if [[ "$(get COMPOSE_HEALTH_AFTER)" -gt 0 && "$count" -ge "$(get COMPOSE_HEALTH_AFTER)" ]]; then
          [[ "$(get PGB_HEALTH)" != starting ]] || setv PGB_HEALTH healthy
          [[ "$(get REDIS_HEALTH)" != starting ]] || setv REDIS_HEALTH healthy
        fi
        if [[ "$(get RESTART_AFTER_INSPECT)" -gt 0 && "$count" -ge "$(get RESTART_AFTER_INSPECT)" ]]; then setv "${prefix}_RESTARTS" 1; fi
      fi
      name=$(get "${prefix}_NAME")
      [[ "$prefix" != PG ]] || name=eventsales-prod-postgres-1
      mounts='[]'
      networks='{}'
      case "$prefix:$(get "${prefix}_MOUNTS")" in
        PG:valid) mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Source":"FIXTURE_VOLUME_SOURCE","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"FIXTURE_SECRET_DIR/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]' ;;
        PGB:valid) mounts='[{"Type":"bind","Source":"FIXTURE_SECRET_DIR/pgbouncer.ini","Destination":"/etc/pgbouncer/pgbouncer.ini","RW":false},{"Type":"bind","Source":"FIXTURE_SECRET_DIR/pgbouncer_users.txt","Destination":"/run/secrets/pgbouncer_users.txt","RW":false}]' ;;
        REDIS:valid) mounts='[{"Type":"bind","Source":"FIXTURE_SECRET_DIR/redis-users.acl","Destination":"/run/secrets/redis-users.acl","RW":false}]' ;;
      esac
      mounts=${mounts//FIXTURE_VOLUME_SOURCE/$(get PG_VOLUME_SOURCE)}
      [[ "$(get "${prefix}_NETWORKS")" != valid ]] || networks="{\"eventsales-prod_eventsales_data\":{\"NetworkID\":\"$(get ATTACHED_DATA_NETWORK_ID)\"}}"
      [[ "$(get "${prefix}_NETWORKS")" != wrong-id ]] || networks="{\"eventsales-prod_eventsales_data\":{\"NetworkID\":\"$(printf '8%.0s' {1..64})\"}}"
      [[ "$(get "${prefix}_NETWORKS")" != edge ]] || networks="{\"eventsales-prod_eventsales_edge\":{\"NetworkID\":\"$(get ATTACHED_EDGE_NETWORK_ID)\"}}"
      [[ "$(get "${prefix}_NETWORKS")" != extra ]] || networks="{\"eventsales-prod_eventsales_data\":{\"NetworkID\":\"$(get ATTACHED_DATA_NETWORK_ID)\"},\"eventsales-prod_eventsales_edge\":{\"NetworkID\":\"$(get ATTACHED_EDGE_NETWORK_ID)\"}}"
      [[ "$(get "${prefix}_NETWORKS")" != empty ]] || networks='{}'
      [[ "$(get "${prefix}_MOUNTS")" != wrong ]] || mounts='[]'
      command_json=$(get "${prefix}_COMMAND")
      [[ "$command_json" != valid ]] || case "$prefix" in
        PG) command_json='["-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]' ;;
        REDIS) command_json='["redis-server","/etc/redis/redis.conf","--bind","0.0.0.0","--protected-mode","no","--aclfile","/run/secrets/redis-users.acl","--maxmemory","384mb","--maxmemory-policy","noeviction","--save","","--appendonly","no","--dir","/tmp","--logfile",""]' ;;
        PGB) command_json='[]' ;;
      esac
      printf '%s|/%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$id" "$name" "$(get "${prefix}_STATUS")" "$(get "${prefix}_RUNNING")" "$(get "${prefix}_RESTARTING")" \
        "$(get "${prefix}_HEALTH")" "$(get "${prefix}_RESTARTS")" "$(get "${prefix}_OOM")" \
        "$(get "${prefix}_IMAGE")" "$(get "${prefix}_MEMORY")" "$(get "${prefix}_NANO")" \
        "$(get "${prefix}_USER")" "$(get "${prefix}_READONLY")" "$capdrop" \
        "$security" "$tmpfs" "$mounts" "$networks" "$ports" "$command_json" | \
        /usr/bin/sed -e 's|FIXTURE_SECRET_DIR|FIXTURE_SECRET_SOURCE|g'
    else exit 1
    fi
    ;;
  network)
    name=${@: -1}
    case "$name" in
      eventsales-prod_eventsales_data) printf '%s|%s|%s|%s\n' "$(get DATA_NETWORK_ID)" "$name" "$(get DATA_NETWORK_DRIVER)" "$(get DATA_NETWORK_INTERNAL)" ;;
      eventsales-prod_eventsales_edge) printf '%s|%s|%s|%s\n' "$(get EDGE_NETWORK_ID)" "$name" "$(get EDGE_NETWORK_DRIVER)" "$(get EDGE_NETWORK_INTERNAL)" ;;
      *) exit 1 ;;
    esac
    ;;
  volume)
    [[ "$(get VOLUME_PRESENT)" == yes ]] || exit 1
    printf '%s|%s|%s|%s\n' "$(get VOLUME_NAME)" "$(get VOLUME_DRIVER)" "$(get VOLUME_SCOPE)" "$(get VOLUME_PATH)"
    ;;
  compose)
    [[ $# -eq 12 && "$2" == --project-name && "$3" == eventsales-prod && "$4" == --env-file \
      && "$5" == /dev/null && "$6" == -f && "$7" == *'/data-plane/compose.yaml' \
      && "$8" == up && "$9" == -d && "${10}" == --no-deps && "${11}" == pgbouncer && "${12}" == redis ]] || exit 89
    [[ "${DOCKER_HOST-}" == unix:///var/run/docker.sock && "${EVENTSALES_SECRET_DIR-}" == FIXTURE_SECRET_SOURCE \
      && -z "${DOCKER_CONTEXT-}${DOCKER_CONFIG-}${COMPOSE_PROJECT_NAME-}${COMPOSE_FILE-}" ]] || exit 88
    create=$(get COMPOSE_CREATE)
    [[ "$create" != pgbouncer && "$create" != both ]] || setv PGB_PRESENT yes
    [[ "$create" != redis && "$create" != both ]] || setv REDIS_PRESENT yes
    rows=$(get PG_ID)'|eventsales-prod-postgres-1'
    [[ "$(get PGB_PRESENT)" != yes ]] || rows+=",$(get PGB_ID)|eventsales-prod-pgbouncer-1"
    [[ "$(get REDIS_PRESENT)" != yes ]] || rows+=",$(get REDIS_ID)|eventsales-prod-redis-1"
    [[ "$(get COMPOSE_EXTRA)" != yes ]] || rows+=",$(printf 'd%.0s' {1..64})|eventsales-prod-unknown-1"
    setv PROJECT_ROWS "$rows"
    setv NAME_ROWS "$rows"
    [[ "$(get COMPOSE_UNLABELED)" != yes ]] || setv NAME_ROWS "$rows,$(printf 'e%.0s' {1..64})|eventsales-prod-unknown-unlabeled-1"
    [[ "$(get COMPOSE_APP)" != yes ]] || { setv APP_PROJECT_ROWS "$(printf 'f%.0s' {1..64})|eventsales-app-1"; setv APP_NAME_ROWS "$(get APP_PROJECT_ROWS)"; }
    case "$(get COMPOSE_PG_DRIFT)" in
      image) setv PG_IMAGE wrong ;;
      running) setv PG_RUNNING false; setv PG_STATUS exited ;;
      restart) setv PG_RESTARTS 1 ;;
      *) ;;
    esac
    case "$(get COMPOSE_D0_DRIFT)" in
      running) setv D0_RUNNING true ;;
      identity) setv D0_PROJECT_ROWS "$(printf '6%.0s' {1..64})|eventsales-d0-proof-postgres-1,$(get D0_PROJECT_ROWS | cut -d, -f2-)"; setv D0_NAME_ROWS "$(get D0_PROJECT_ROWS)" ;;
      count) setv D0_PROJECT_ROWS "$(get D0_PROJECT_ROWS | cut -d, -f1-2)"; setv D0_NAME_ROWS "$(get D0_PROJECT_ROWS)" ;;
      *) ;;
    esac
    [[ "$(get COMPOSE_NETWORK_DRIFT)" != yes ]] || setv DATA_NETWORK_ID "$(printf '7%.0s' {1..64})"
    [[ "$(get COMPOSE_VOLUME_DRIFT)" != yes ]] || setv VOLUME_PATH 'FIXTURE_VOLUME_ALT'
    [[ "$(get COMPOSE_HEALTH)" != starting ]] || { setv PGB_HEALTH starting; setv REDIS_HEALTH starting; }
    [[ "$(get COMPOSE_HEALTH_AFTER)" -gt 0 ]] || true
    [[ "$(get COMPOSE_STATUS)" == 0 ]] || exit 1
    ;;
  *) exit 92 ;;
esac
DOCKER

cat >"$fixture_bin/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
format=${2-}
target=${@: -1}
override_target=$(/usr/bin/awk -F= '$1=="META_OVERRIDE_TARGET"{sub(/^[^=]*=/,"");print;exit}' "$state")
override_value=$(/usr/bin/awk -F= '$1=="META_OVERRIDE_VALUE"{sub(/^[^=]*=/,"");print;exit}' "$state")
if [[ "$target" == "$override_target" && "$override_value" != none ]]; then printf '%s\n' "$override_value"; exit 0; fi
if [[ "$format" == '%u:%g:%a' || "$format" == '%u:%g:%a:%s' ]]; then
  actual=$(/usr/bin/stat -c "$format" -- "$target")
  IFS=: read -r uid gid mode size <<<"$actual"
  if [[ "$target" == *'/eventsales-prod/secrets-v1/'* ]]; then
    uid=0
    case "$target" in
      */pgbouncer.ini|*/pgbouncer_users.txt|*/redis-users.acl) gid=65532 ;;
      *) gid=0 ;;
    esac
  else uid='FIXTURE_UID'; gid='FIXTURE_GID'; fi
  if [[ "$format" == '%u:%g:%a' ]]; then printf '%s:%s:%s\n' "$uid" "$gid" "$mode"; else printf '%s:%s:%s:%s\n' "$uid" "$gid" "$mode" "$size"; fi
else /usr/bin/stat "$@"; fi
STAT

cat >"$fixture_bin/mkdir" <<'MKDIR'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
fail=$(/usr/bin/awk -F= '$1=="CREATE_MARKER_FAIL"{sub(/^[^=]*=/,"");print;exit}' "$state")
target=${@: -1}
if [[ "$fail" == yes && "$target" == *'.v4-pgbouncer-redis-start-consumed' ]]; then exit 1; fi
exec /usr/bin/mkdir "$@"
MKDIR

chmod 0755 "$fixture_bin/docker" "$fixture_bin/stat" "$fixture_bin/mkdir"
printf 'exit 99\n' >"$hostile_bash_env"
chmod 0600 "$hostile_bash_env"

render_fixtures() {
  /usr/bin/sed -i \
    -e "s|FIXTURE_STATE|$state_file|g" \
    -e "s|FIXTURE_LOG|$docker_log|g" \
    -e "s|FIXTURE_SECRET_SOURCE|$secret_fixture|g" \
    -e "s|FIXTURE_SECRET_DIR|$secret_fixture|g" \
    -e "s|FIXTURE_VOLUME_ALT|$volume_alt_fixture|g" \
    -e "s|FIXTURE_UID|$fixture_uid|g" \
    -e "s|FIXTURE_GID|$fixture_gid|g" \
    "$fixture_bin/docker"
  /usr/bin/sed -i -e "s|FIXTURE_STATE|$state_file|g" -e "s|FIXTURE_UID|$fixture_uid|g" -e "s|FIXTURE_GID|$fixture_gid|g" "$fixture_bin/stat"
  /usr/bin/sed -i -e "s|FIXTURE_STATE|$state_file|g" "$fixture_bin/mkdir"
}

render_test_wrapper() {
  /usr/bin/sed \
    -e "s|/root|$root_fixture|g" \
    -e "s|readonly SAFE_PATH='/usr/sbin:/usr/bin:/sbin:/bin'|readonly SAFE_PATH='$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin'|" \
    -e "s|readonly ROOT_UID='0'|readonly ROOT_UID='$fixture_uid'|" \
    -e "s|readonly ROOT_GID='0'|readonly ROOT_GID='$fixture_gid'|" \
    -e "s|readonly HEALTH_TIMEOUT=120|readonly HEALTH_TIMEOUT=5|" \
    -e "s|readonly HEALTH_INTERVAL=2|readonly HEALTH_INTERVAL=1|" \
    -e 's/((EUID != ROOT_UID))/((TEST_EUID != ROOT_UID))/' \
    "$wrapper_source" >"$wrapper_fixture"
  chmod 0755 "$wrapper_fixture"
}

reset_case() {
  make_filesystem
  write_state
  render_fixtures
  render_test_wrapper
}

run_wrapper() {
  local test_euid=$fixture_uid status=0
  if (($#)) && [[ "$1" == --non-root ]]; then test_euid=999; shift; fi
  env TEST_EUID="$test_euid" PATH="$fixture_bin:/usr/bin:/bin" \
    DOCKER_HOST='tcp://attacker.invalid:2375' DOCKER_CONTEXT='caller-context' \
    DOCKER_CONFIG='/caller/docker-config' COMPOSE_PROJECT_NAME='caller-project' \
    COMPOSE_FILE='/caller/compose.yaml' EVENTSALES_SECRET_DIR='/caller/secrets' \
    BASH_ENV="$hostile_bash_env" ENV='/caller/env' CDPATH='/caller/cdpath' \
    "$wrapper_fixture" "$@" >"$out" 2>"$err" || status=$?
  return "$status"
}

call_count() { /usr/bin/grep -c "^CALL|$1" "$docker_log" || true; }
marker_path="$root_fixture/eventsales-prod/.v4-pgbouncer-redis-start-consumed"

assert_no_mutations() {
  local label=$1 expected_compose=${2:-0}
  [[ "$(call_count 'compose ')" -eq "$expected_compose" ]] || fail "$label used an unexpected Compose count"
  ! /usr/bin/grep -Eq '^CALL\|(stop|rm|restart|kill|pause|unpause|down|volume (rm|create|prune)|network (create|rm|connect|disconnect)|system prune)' "$docker_log" || fail "$label called a forbidden Docker mutation"
  ! /usr/bin/grep -Eq '^CALL\|compose .* (postgres|down|--force-recreate|--remove-orphans)' "$docker_log" || fail "$label targeted PostgreSQL or requested a forbidden Compose operation"
}

expect_preflight_stop() {
  local label=$1 reason=$2 marker_expectation=${3:-absent} status=0
  run_wrapper || status=$?
  ((status != 0)) || { cat "$out" "$err" >&2; fail "$label unexpectedly succeeded"; }
  /usr/bin/grep -Fxq 'V4_STATE=V4_PREFLIGHT_BLOCKED' "$err" || { cat "$err" >&2; fail "$label did not report a preflight block"; }
  /usr/bin/grep -Fxq "STOP=$reason" "$err" || { cat "$err" "$docker_log" >&2; fail "$label stopped for the wrong reason"; }
  if [[ "$marker_expectation" == absent ]]; then
    [[ ! -e "$marker_path" && ! -L "$marker_path" ]] || fail "$label consumed V4 authority during preflight"
  else
    [[ -e "$marker_path" || -L "$marker_path" ]] || fail "$label removed the conflicting marker"
  fi
  assert_no_mutations "$label" 0
  pass "$label"
}

expect_postconsume_stop() {
  local label=$1 reason=$2 status=0
  run_wrapper || status=$?
  ((status != 0)) || { cat "$out" "$err" >&2; fail "$label unexpectedly succeeded"; }
  /usr/bin/grep -Fxq 'V4_STATE=BLOCKED_B4' "$err" || fail "$label did not report BLOCKED_B4"
  /usr/bin/grep -Fxq "STOP=$reason" "$err" || { cat "$err" >&2; fail "$label stopped for the wrong reason"; }
  [[ -d "$marker_path" && ! -L "$marker_path" ]] || fail "$label did not preserve the consumed marker"
  assert_no_mutations "$label" 1
  pass "$label"
}

expect_data_plane_running() {
  local label=$1 status=0
  run_wrapper || status=$?
  if ((status != 0)); then
    if /usr/bin/grep -Fxq 'STOP=D0_CONTRACT_MISMATCH' "$err"; then
      fail "$label was rejected with D0_CONTRACT_MISMATCH"
    fi
    cat "$out" "$err" >&2
    fail "$label did not reach DATA_PLANE_RUNNING"
  fi
  /usr/bin/grep -Fxq 'V4_STATE=DATA_PLANE_RUNNING' "$out" || fail "$label did not report DATA_PLANE_RUNNING"
  [[ -d "$marker_path" && ! -L "$marker_path" ]] || fail "$label did not consume the V4 marker"
  pass "$label"
}

[[ -f "$wrapper_source" && ! -L "$wrapper_source" ]] || fail 'V4 wrapper source is missing'

# The wrapper must reject caller arguments and non-root invocation before Docker access.
reset_case
status=0; run_wrapper forbidden-argument || status=$?
((status != 0)) || fail 'caller arguments were accepted'
/usr/bin/grep -Fxq 'STOP=CALLER_ARGUMENTS_FORBIDDEN' "$err" || fail 'caller arguments stopped for the wrong reason'
[[ ! -e "$marker_path" ]] || fail 'caller arguments consumed the marker'
assert_no_mutations 'caller arguments'
pass 'caller arguments rejected before mutation'

reset_case
status=0; run_wrapper --non-root || status=$?
((status != 0)) || fail 'non-root invocation was accepted'
/usr/bin/grep -Fxq 'STOP=ROOT_REQUIRED' "$err" || fail 'non-root invocation stopped for the wrong reason'
assert_no_mutations 'non-root invocation'
pass 'non-root invocation rejected before mutation'

# Accepted D0 project-prefixed names include the production service-style names.
reset_case
expect_data_plane_running 'accepts production-style D0 service names'

reset_case
generic_d0_rows="$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1,$d0_three|eventsales-d0-proof-custom-worker-7"
set_state D0_PROJECT_ROWS "$generic_d0_rows"
set_state D0_NAME_ROWS "$generic_d0_rows"
set_state D0_ROWS "$generic_d0_rows"
expect_data_plane_running 'accepts a generic project-prefixed D0 name'

# Preflight authority and immutable-stage failures never consume the marker.
for item in \
  'recovery marker missing|RECOVERY_MARKER_INVALID|RECOVERY_MARKER_MISSING' \
  'bootstrap marker missing|BOOTSTRAP_MARKER_INVALID|BOOTSTRAP_MARKER_MISSING' \
  'data network driver|NETWORK_IDENTITY_MISMATCH|DATA_NETWORK_DRIVER' \
  'data network internal flag|NETWORK_IDENTITY_MISMATCH|DATA_NETWORK_INTERNAL' \
  'edge network driver|NETWORK_IDENTITY_MISMATCH|EDGE_NETWORK_DRIVER' \
  'edge network internal flag|NETWORK_IDENTITY_MISMATCH|EDGE_NETWORK_INTERNAL' \
  'missing PostgreSQL volume|POSTGRES_VOLUME_IDENTITY_MISMATCH|VOLUME_PRESENT' \
  'wrong PostgreSQL volume name|POSTGRES_VOLUME_IDENTITY_MISMATCH|VOLUME_NAME' \
  'wrong PostgreSQL volume driver|POSTGRES_VOLUME_IDENTITY_MISMATCH|VOLUME_DRIVER' \
  'wrong PostgreSQL volume scope|POSTGRES_VOLUME_IDENTITY_MISMATCH|VOLUME_SCOPE' \
  'unhealthy PostgreSQL|POSTGRES_CONTRACT_MISMATCH|PG_HEALTH' \
  'restarted PostgreSQL|POSTGRES_CONTRACT_MISMATCH|PG_RESTARTS' \
  'OOM PostgreSQL|POSTGRES_CONTRACT_MISMATCH|PG_OOM' \
  'wrong PostgreSQL image|POSTGRES_CONTRACT_MISMATCH|PG_IMAGE' \
  'wrong PostgreSQL memory|POSTGRES_CONTRACT_MISMATCH|PG_MEMORY' \
  'wrong PostgreSQL CPU|POSTGRES_CONTRACT_MISMATCH|PG_NANO' \
  'wrong PostgreSQL mounts|POSTGRES_CONTRACT_MISMATCH|PG_MOUNTS' \
  'wrong PostgreSQL network|POSTGRES_CONTRACT_MISMATCH|PG_NETWORKS' \
  'wrong PostgreSQL volume source|POSTGRES_CONTRACT_MISMATCH|PG_VOLUME_SOURCE' \
  'PostgreSQL host port|POSTGRES_CONTRACT_MISMATCH|PG_PORTS' \
  'wrong PostgreSQL command|POSTGRES_CONTRACT_MISMATCH|PG_COMMAND' \
  'unexpected production object|UNEXPECTED_PRODUCTION_CONTAINER|COMPOSE_EXTRA' \
  'application project container|APP_CONTAINER_PRESENT|COMPOSE_APP' \
  'D0 running|D0_CONTRACT_MISMATCH|D0_RUNNING' \
  'D0 restarting|D0_CONTRACT_MISMATCH|D0_RESTARTING'; do
  IFS='|' read -r label reason key <<<"$item"
  reset_case
  case "$key" in
    RECOVERY_MARKER_MISSING) rm -rf -- "$root_fixture/eventsales-prod/.v3-postgres-recovery-consumed" ;;
    BOOTSTRAP_MARKER_MISSING) rm -rf -- "$root_fixture/eventsales-prod/.v3-postgres-bootstrap-v2-consumed" ;;
    COMPOSE_EXTRA) set_state PROJECT_ROWS "$(get_state PROJECT_ROWS),$(printf 'd%.0s' {1..64})|eventsales-prod-unknown-1"; set_state NAME_ROWS "$(get_state PROJECT_ROWS)" ;;
    COMPOSE_APP) set_state APP_PROJECT_ROWS "$(printf 'e%.0s' {1..64})|eventsales-app-1"; set_state APP_NAME_ROWS "$(get_state APP_PROJECT_ROWS)" ;;
    *) set_state "$key" bad ;;
  esac
  expect_preflight_stop "$label" "$reason"
done

reset_case
set_state PG_NETWORKS wrong-id
expect_preflight_stop 'wrong PostgreSQL network ID' POSTGRES_CONTRACT_MISMATCH

for meta_case in \
  'data network internal|DATA_NETWORK_INTERNAL|false|NETWORK_IDENTITY_MISMATCH' \
  'edge network internal|EDGE_NETWORK_INTERNAL|true|NETWORK_IDENTITY_MISMATCH' \
  'PostgreSQL not running|PG_RUNNING|false|POSTGRES_CONTRACT_MISMATCH' \
  'PostgreSQL restarting|PG_RESTARTING|true|POSTGRES_CONTRACT_MISMATCH' \
  'PostgreSQL wrong status|PG_STATUS|exited|POSTGRES_CONTRACT_MISMATCH' \
  'D0 not exited|D0_STATUS|running|D0_CONTRACT_MISMATCH' \
  'D0 running flag|D0_RUNNING|true|D0_CONTRACT_MISMATCH' \
  'D0 restarting flag|D0_RESTARTING|true|D0_CONTRACT_MISMATCH'; do
  IFS='|' read -r label key value reason <<<"$meta_case"
  reset_case
  set_state "$key" "$value"
  expect_preflight_stop "$label" "$reason"
done

# Each D0 inventory must contain three unique full IDs and names in the accepted namespace.
for d0_case in count identity name-inventory invalid-namespace duplicate-id duplicate-name; do
  reset_case
  case "$d0_case" in
    count) set_state D0_PROJECT_ROWS "$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1"; set_state D0_NAME_ROWS "$(get_state D0_PROJECT_ROWS)" ;;
    identity) set_state D0_PROJECT_ROWS "$(printf '6%.0s' {1..64})|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1,$d0_three|eventsales-d0-proof-redis-1"; set_state D0_NAME_ROWS "$(get_state D0_PROJECT_ROWS)" ;;
    name-inventory) set_state D0_NAME_ROWS "$(get_state D0_NAME_ROWS),$(printf '7%.0s' {1..64})|eventsales-d0-proof-unlabeled" ;;
    invalid-namespace) set_state D0_PROJECT_ROWS "$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-pgbouncer-1,$d0_three|outside-d0-proof-namespace"; set_state D0_NAME_ROWS "$(get_state D0_PROJECT_ROWS)"; set_state D0_ROWS "$(get_state D0_PROJECT_ROWS)" ;;
    duplicate-id) set_state D0_PROJECT_ROWS "$d0_one|eventsales-d0-proof-postgres-1,$d0_one|eventsales-d0-proof-pgbouncer-1,$d0_three|eventsales-d0-proof-redis-1"; set_state D0_NAME_ROWS "$(get_state D0_PROJECT_ROWS)"; set_state D0_ROWS "$(get_state D0_PROJECT_ROWS)" ;;
    duplicate-name) set_state D0_PROJECT_ROWS "$d0_one|eventsales-d0-proof-postgres-1,$d0_two|eventsales-d0-proof-postgres-1,$d0_three|eventsales-d0-proof-redis-1"; set_state D0_NAME_ROWS "$(get_state D0_PROJECT_ROWS)"; set_state D0_ROWS "$(get_state D0_PROJECT_ROWS)" ;;
  esac
  expect_preflight_stop "D0 $d0_case drift" D0_CONTRACT_MISMATCH
done

reset_case
set_state D0_DRIFT_BEFORE_MARKER identity
expect_preflight_stop 'D0 inventory changed before marker' D0_CHANGED_BEFORE_MARKER

# Marker conflicts and creation failure must remain pre-mutation.
for marker_kind in directory file symlink; do
  reset_case
  case "$marker_kind" in
    directory) mkdir -m 0700 "$marker_path" ;;
    file) : >"$marker_path" ;;
    symlink) ln -s "$root_fixture/eventsales-prod" "$marker_path" ;;
  esac
  expect_preflight_stop "V4 marker existing as $marker_kind" V4_AUTHORITY_ALREADY_CONSUMED present
done
reset_case
set_state CREATE_MARKER_FAIL yes
expect_preflight_stop 'atomic V4 marker creation failure' V4_MARKER_CREATE_FAILED

# Root-owned path metadata, symlinks, Compose bytes and secret metadata fail closed.
reset_case
chmod -R u+w "$stage_fixture"
chmod 0755 "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107"
rm -rf -- "$stage_fixture"
ln -s "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107" "$stage_fixture"
set_state META_OVERRIDE_TARGET "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107"
set_state META_OVERRIDE_VALUE "$fixture_uid:$fixture_gid:555"
expect_preflight_stop 'immutable stage symlink' C9CE_STAGE_DIRECTORY_SYMLINK

reset_case
set_state META_OVERRIDE_TARGET "$stage_fixture"
set_state META_OVERRIDE_VALUE "$fixture_uid:$fixture_gid:0777"
expect_preflight_stop 'writable immutable stage directory' C9CE_STAGE_DIRECTORY_WRITABLE

reset_case
set_state META_OVERRIDE_TARGET "$stage_fixture"
set_state META_OVERRIDE_VALUE "$fixture_uid:$fixture_gid:0755"
expect_preflight_stop 'owner-writable immutable stage directory' C9CE_STAGE_DIRECTORY_WRITABLE

reset_case
set_state META_OVERRIDE_TARGET "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107"
set_state META_OVERRIDE_VALUE "$fixture_uid:$fixture_gid:0755"
expect_preflight_stop 'owner-writable source-SHA directory' C9CE_STAGE_DIRECTORY_WRITABLE

reset_case
set_state META_OVERRIDE_TARGET "$stage_fixture/compose.yaml"
set_state META_OVERRIDE_VALUE "$((fixture_uid + 1)):$fixture_gid:444"
expect_preflight_stop 'Compose owner drift' COMPOSE_OWNER_MISMATCH

reset_case
chmod 0644 "$stage_fixture/compose.yaml"
expect_preflight_stop 'writable Compose file' COMPOSE_WRITABLE

reset_case
chmod 0644 "$stage_fixture/compose.yaml"
printf 'changed Compose\n' >"$stage_fixture/compose.yaml"
chmod 0444 "$stage_fixture/compose.yaml"
expect_preflight_stop 'Compose hash drift' COMPOSE_HASH_MISMATCH

reset_case
chmod 0755 "$stage_fixture"
rm "$stage_fixture/compose.yaml"
ln -s "$compose_source" "$stage_fixture/compose.yaml"
set_state META_OVERRIDE_TARGET "$stage_fixture"
set_state META_OVERRIDE_VALUE "$fixture_uid:$fixture_gid:555"
expect_preflight_stop 'Compose symlink' COMPOSE_SYMLINK

for secret_case in \
  'runtime server password|eventsales_runtime_server_password|0000' \
  'runtime client password|eventsales_runtime_client_password|0000' \
  'Redis runtime password|redis_runtime_password|0000' \
  'Redis stats password|redis_stats_password|0000' \
  'PgBouncer config|pgbouncer.ini|0444' \
  'PgBouncer users|pgbouncer_users.txt|0444' \
  'Redis ACL|redis-users.acl|0444'; do
  IFS='|' read -r label filename mode <<<"$secret_case"
  reset_case
  chmod "$mode" "$secret_fixture/$filename"
  expect_preflight_stop "$label metadata drift" SECRET_FILE_METADATA_MISMATCH
done

for secret_marker in recovery bootstrap; do
  reset_case
  if [[ "$secret_marker" == recovery ]]; then target="$root_fixture/eventsales-prod/.v3-postgres-recovery-consumed"; reason=RECOVERY_MARKER_METADATA_MISMATCH
  else target="$root_fixture/eventsales-prod/.v3-postgres-bootstrap-v2-consumed"; reason=BOOTSTRAP_MARKER_METADATA_MISMATCH; fi
  chmod 0755 "$target"
  expect_preflight_stop "$secret_marker marker mode drift" "$reason"
done

reset_case
set_state PROJECT_ROWS "$(get_state PROJECT_ROWS),$(printf 'd%.0s' {1..64})|eventsales-prod-extra"
expect_preflight_stop 'project and name inventory mismatch' PRODUCTION_INVENTORY_MISMATCH

reset_case
set_state PG_PRESENT no
set_state PROJECT_ROWS ''
set_state NAME_ROWS ''
expect_preflight_stop 'PostgreSQL missing' POSTGRES_CONTAINER_MISSING

# The Docker fixture reproduces Go-template's missing-map-key failure when a
# wrapper directly dereferences an absent HostConfig field. PostgreSQL and
# Redis legitimately have no Tmpfs key; PgBouncer must retain its exact map.
reset_case
set_state PG_TMPFS_KEY ABSENT
set_state REDIS_TMPFS_KEY ABSENT
set_state PGB_TMPFS_KEY PRESENT
status=0; run_wrapper || status=$?
if ((status != 0)); then
  /usr/bin/grep -Fq 'TEMPLATE_ERROR|PG|Tmpfs|missing-key' "$docker_log" \
    || fail 'fake Docker did not reproduce the missing PostgreSQL Tmpfs template error'
  /usr/bin/grep -Fxq 'STOP=POSTGRES_CONTRACT_MISMATCH' "$err" \
    || fail 'missing PostgreSQL Tmpfs key stopped for an unexpected reason'
  fail 'missing HostConfig.Tmpfs key was not normalized; regression reproduced the Docker template failure'
fi
[[ -d "$marker_path" && ! -L "$marker_path" ]] || fail 'absent Tmpfs success did not complete V4 transition'
/usr/bin/grep -Fq 'HOSTCONFIG|PG|CapDrop=[]|SecurityOpt=[]|Tmpfs={}|PortBindings={}' "$docker_log" \
  || fail 'PostgreSQL absent HostConfig fields were not normalized safely'
/usr/bin/grep -Fq 'HOSTCONFIG|REDIS|CapDrop=["ALL"]|SecurityOpt=["no-new-privileges:true"]|Tmpfs={}|PortBindings={}' "$docker_log" \
  || fail 'Redis absent Tmpfs was not normalized to the no-Tmpfs representation'
/usr/bin/grep -Fq 'HOSTCONFIG|PGB|CapDrop=["ALL"]|SecurityOpt=["no-new-privileges:true"]|Tmpfs={"/tmp":"rw,noexec,nosuid,size=16m,mode=1777"}|PortBindings={}' "$docker_log" \
  || fail 'PgBouncer exact Tmpfs map was not preserved'
pass 'optional HostConfig.Tmpfs keys normalize for PostgreSQL and Redis while PgBouncer retains its required map'

reset_case
set_state PG_CAPDROP_KEY ABSENT
set_state PG_SECURITY_KEY ABSENT
set_state PG_PORTBINDINGS_KEY ABSENT
set_state PGB_PORTBINDINGS_KEY ABSENT
set_state REDIS_PORTBINDINGS_KEY ABSENT
status=0; run_wrapper || status=$?
((status == 0)) || { cat "$out" "$err" "$docker_log" >&2; fail 'other optional HostConfig keys did not normalize safely'; }
/usr/bin/grep -Fq 'HOSTCONFIG|PG|CapDrop=[]|SecurityOpt=[]|Tmpfs={}|PortBindings={}' "$docker_log" \
  || fail 'absent PostgreSQL CapDrop, SecurityOpt or PortBindings were not normalized'
/usr/bin/grep -Fq 'HOSTCONFIG|PGB|CapDrop=["ALL"]|SecurityOpt=["no-new-privileges:true"]|Tmpfs={"/tmp":"rw,noexec,nosuid,size=16m,mode=1777"}|PortBindings={}' "$docker_log" \
  || fail 'absent PgBouncer PortBindings were not normalized'
/usr/bin/grep -Fq 'HOSTCONFIG|REDIS|CapDrop=["ALL"]|SecurityOpt=["no-new-privileges:true"]|Tmpfs={}|PortBindings={}' "$docker_log" \
  || fail 'absent Redis PortBindings were not normalized'
pass 'other optional HostConfig map keys normalize without weakening service checks'

# A complete fake Compose transition validates exact targets and sanitized environment.
reset_case
status=0; run_wrapper || status=$?
((status == 0)) || { cat "$out" "$err" "$docker_log" >&2; fail 'valid V4 fixture failed'; }
[[ "$(call_count 'compose ')" -eq 1 ]] || fail 'success did not invoke Compose exactly once'
/usr/bin/grep -Fq 'compose --project-name eventsales-prod --env-file /dev/null' "$docker_log" || fail 'Compose project or env-file contract mismatch'
/usr/bin/grep -Fq -- 'up -d --no-deps pgbouncer redis' "$docker_log" || fail 'Compose targets or no-deps option mismatch'
assert_no_mutations 'successful V4 transition' 1
expected_success=$(cat <<'EOF'
DATA_PLANE=RUNNING
V4_STATE=DATA_PLANE_RUNNING
POSTGRES_STATUS=running
POSTGRES_HEALTH=healthy
POSTGRES_RESTART_COUNT=0
PGBOUNCER_STATUS=running
PGBOUNCER_HEALTH=healthy
PGBOUNCER_RESTART_COUNT=0
PGBOUNCER_IMAGE_MATCH=YES
REDIS_STATUS=running
REDIS_HEALTH=healthy
REDIS_RESTART_COUNT=0
REDIS_IMAGE_MATCH=YES
DATA_PLANE_NETWORK_ONLY=YES
DATA_SERVICE_HOST_PORTS=NONE
APP_STARTED=NO
D0_STATE=ARCHIVED_STOPPED
EOF
)
[[ "$(cat "$out")" == "$expected_success" ]] || fail 'success output differs from the safe deterministic contract'
[[ ! -s "$err" ]] || fail 'successful V4 run wrote unexpected stderr'
if /usr/bin/grep -Eq 'attacker\.invalid|caller-context|caller-project|caller/secrets|caller/docker-config|caller-bash-env' "$docker_log"; then fail 'caller environment reached Docker'; fi
[[ -d "$marker_path" && ! -L "$marker_path" ]] || fail 'success did not retain one-shot marker'
pass 'success invokes one sanitized no-deps Compose start for PgBouncer and Redis only'

# Caller environment cannot select Compose files, Docker contexts or host endpoints.
reset_case
status=0; run_wrapper || status=$?
((status == 0)) || fail 'valid V4 transition failed with hostile Docker environment'
/usr/bin/grep -Fq 'host=unix:///var/run/docker.sock' "$docker_log" || fail 'Docker host was not fixed'
if /usr/bin/grep -Eq 'attacker\.invalid|caller-context|caller-project|caller/secrets|caller/docker-config|caller-bash-env' "$docker_log"; then fail 'hostile caller environment was retained'; fi
pass 'Docker and Compose environment is sanitized'

# Compose failure after each partial-creation point consumes authority without rollback.
for create_mode in none pgbouncer redis both; do
  reset_case
  set_state COMPOSE_CREATE "$create_mode"
  set_state COMPOSE_STATUS 1
  expect_postconsume_stop "Compose failure after $create_mode creation" V4_COMPOSE_START_FAILED
done

# Missing, ambiguous, invalid and reused service IDs fail without a second Compose call.
for service_case in missing-pgbouncer missing-redis invalid-pgbouncer-id invalid-redis-id reused-pg-id reused-service-id duplicate-name; do
  reset_case
  case "$service_case" in
    missing-pgbouncer) set_state COMPOSE_CREATE redis ;;
    missing-redis) set_state COMPOSE_CREATE pgbouncer ;;
    invalid-pgbouncer-id) set_state PGB_ID short ;;
    invalid-redis-id) set_state REDIS_ID short ;;
    reused-pg-id) set_state PGB_ID "$pg_id" ;;
    reused-service-id) set_state REDIS_ID "$pgbouncer_id" ;;
    duplicate-name) set_state COMPOSE_EXTRA yes ;;
  esac
  expect_postconsume_stop "$service_case" V4_SERVICE_INVENTORY_MISMATCH
done

# PgBouncer contract drift is terminal and does not trigger any service mutation.
for service_case in \
  'image|PGB_IMAGE|wrong|PGBOUNCER_CONTRACT_MISMATCH' \
  'stopped|PGB_RUNNING|false|PGBOUNCER_CONTRACT_MISMATCH' \
  'restarting|PGB_RESTARTING|true|PGBOUNCER_CONTRACT_MISMATCH' \
  'restart count|PGB_RESTARTS|1|PGBOUNCER_CONTRACT_MISMATCH' \
  'OOM|PGB_OOM|true|PGBOUNCER_CONTRACT_MISMATCH' \
  'user|PGB_USER|1000:1000|PGBOUNCER_CONTRACT_MISMATCH' \
  'memory|PGB_MEMORY|999|PGBOUNCER_CONTRACT_MISMATCH' \
  'CPU|PGB_NANO|999|PGBOUNCER_CONTRACT_MISMATCH' \
  'writable rootfs|PGB_READONLY|false|PGBOUNCER_CONTRACT_MISMATCH' \
  'capabilities|PGB_CAPDROP|[]|PGBOUNCER_CONTRACT_MISMATCH' \
  'missing capabilities key|PGB_CAPDROP_KEY|ABSENT|PGBOUNCER_CONTRACT_MISMATCH' \
  'security options|PGB_SECURITY|[]|PGBOUNCER_CONTRACT_MISMATCH' \
  'missing security options key|PGB_SECURITY_KEY|ABSENT|PGBOUNCER_CONTRACT_MISMATCH' \
  'tmpfs|PGB_TMPFS|{}|PGBOUNCER_CONTRACT_MISMATCH' \
  'missing tmpfs key|PGB_TMPFS_KEY|ABSENT|PGBOUNCER_CONTRACT_MISMATCH' \
  'secret mounts|PGB_MOUNTS|wrong|PGBOUNCER_CONTRACT_MISMATCH' \
  'network|PGB_NETWORKS|edge|PGBOUNCER_CONTRACT_MISMATCH' \
  'network ID|PGB_NETWORKS|wrong-id|PGBOUNCER_CONTRACT_MISMATCH' \
  'host port|PGB_PORTS|{"6432/tcp":[{"HostPort":"6432"}]}|PGBOUNCER_CONTRACT_MISMATCH'; do
  IFS='|' read -r label key value reason <<<"$service_case"
  reset_case
  set_state "$key" "$value"
  expect_postconsume_stop "PgBouncer $label drift" "$reason"
done

# Redis contract drift, including exact command semantics, fails closed.
for service_case in \
  'image|REDIS_IMAGE|wrong|REDIS_CONTRACT_MISMATCH' \
  'stopped|REDIS_RUNNING|false|REDIS_CONTRACT_MISMATCH' \
  'restarting|REDIS_RESTARTING|true|REDIS_CONTRACT_MISMATCH' \
  'restart count|REDIS_RESTARTS|1|REDIS_CONTRACT_MISMATCH' \
  'OOM|REDIS_OOM|true|REDIS_CONTRACT_MISMATCH' \
  'user|REDIS_USER|1000:1000|REDIS_CONTRACT_MISMATCH' \
  'memory|REDIS_MEMORY|999|REDIS_CONTRACT_MISMATCH' \
  'CPU|REDIS_NANO|999|REDIS_CONTRACT_MISMATCH' \
  'writable rootfs|REDIS_READONLY|false|REDIS_CONTRACT_MISMATCH' \
  'capabilities|REDIS_CAPDROP|[]|REDIS_CONTRACT_MISMATCH' \
  'missing capabilities key|REDIS_CAPDROP_KEY|ABSENT|REDIS_CONTRACT_MISMATCH' \
  'security options|REDIS_SECURITY|[]|REDIS_CONTRACT_MISMATCH' \
  'missing security options key|REDIS_SECURITY_KEY|ABSENT|REDIS_CONTRACT_MISMATCH' \
  'wrong tmpfs|REDIS_TMPFS|{"/tmp":"rw"}|REDIS_CONTRACT_MISMATCH' \
  'ACL mount|REDIS_MOUNTS|wrong|REDIS_CONTRACT_MISMATCH' \
  'network|REDIS_NETWORKS|edge|REDIS_CONTRACT_MISMATCH' \
  'network ID|REDIS_NETWORKS|wrong-id|REDIS_CONTRACT_MISMATCH' \
  'host port|REDIS_PORTS|{"6379/tcp":[{"HostPort":"6379"}]}|REDIS_CONTRACT_MISMATCH' \
  'command|REDIS_COMMAND|["redis-server","--wrong"]|REDIS_CONTRACT_MISMATCH'; do
  IFS='|' read -r label key value reason <<<"$service_case"
  reset_case
  set_state "$key" "$value"
  expect_postconsume_stop "Redis $label drift" "$reason"
done

# Polling accepts starting-to-healthy and blocks unhealthy, restarted or timed-out services.
reset_case
set_state COMPOSE_HEALTH starting
set_state COMPOSE_HEALTH_AFTER 2
status=0; run_wrapper || status=$?
((status == 0)) || { cat "$err" "$docker_log" >&2; fail 'starting services did not reach healthy state'; }
/usr/bin/grep -Fxq 'PGBOUNCER_HEALTH=healthy' "$out" || fail 'PgBouncer final health was not healthy'
/usr/bin/grep -Fxq 'REDIS_HEALTH=healthy' "$out" || fail 'Redis final health was not healthy'
pass 'starting services become healthy inside the deadline'

for health_case in pgbouncer-unhealthy redis-unhealthy restart-during-poll timeout; do
  reset_case
  case "$health_case" in
    pgbouncer-unhealthy) set_state PGB_HEALTH unhealthy ;;
    redis-unhealthy) set_state REDIS_HEALTH unhealthy ;;
    restart-during-poll) set_state COMPOSE_HEALTH starting; set_state RESTART_AFTER_INSPECT 1 ;;
    timeout) set_state COMPOSE_HEALTH starting; set_state COMPOSE_HEALTH_AFTER 999 ;;
  esac
  reason=V4_HEALTH_TIMEOUT
  [[ "$health_case" != pgbouncer-unhealthy ]] || reason=PGBOUNCER_HEALTH_UNHEALTHY
  [[ "$health_case" != redis-unhealthy ]] || reason=REDIS_HEALTH_UNHEALTHY
  [[ "$health_case" != restart-during-poll ]] || reason=PGBOUNCER_CONTRACT_MISMATCH
  expect_postconsume_stop "$health_case" "$reason"
done

# Final checks revalidate the same PostgreSQL, inventories, networks, volume, D0 and app absence.
for final_case in postgres-drift extra-container unlabeled-production app-appears D0-running D0-ID-drift network-drift volume-drift host-port; do
  reset_case
  case "$final_case" in
    postgres-drift) set_state COMPOSE_PG_DRIFT image ;;
    extra-container) set_state COMPOSE_EXTRA yes ;;
    unlabeled-production) set_state COMPOSE_UNLABELED yes ;;
    app-appears) set_state COMPOSE_APP yes ;;
    D0-running) set_state COMPOSE_D0_DRIFT running ;;
    D0-ID-drift) set_state COMPOSE_D0_DRIFT identity ;;
    network-drift) set_state COMPOSE_NETWORK_DRIFT yes ;;
    volume-drift) set_state COMPOSE_VOLUME_DRIFT yes ;;
    host-port) set_state PGB_PORTS '{"6432/tcp":[{"HostPort":"6432"}]}' ;;
  esac
  reason=PGBOUNCER_CONTRACT_MISMATCH
  [[ "$final_case" != postgres-drift ]] || reason=POSTGRES_REVALIDATION_FAILED
  [[ "$final_case" != unlabeled-production && "$final_case" != extra-container ]] || reason=V4_SERVICE_INVENTORY_MISMATCH
  [[ "$final_case" != app-appears ]] || reason=APP_CONTAINER_PRESENT
  [[ "$final_case" != D0-running && "$final_case" != D0-ID-drift ]] || reason=D0_CHANGED
  [[ "$final_case" != network-drift ]] || reason=NETWORK_CHANGED
  [[ "$final_case" != volume-drift ]] || reason=POSTGRES_VOLUME_CHANGED
  expect_postconsume_stop "final $final_case revalidation" "$reason"
done

[[ -f "$sudoers_source" && ! -L "$sudoers_source" ]] || fail 'V4 sudoers source is missing or not regular'
[[ "$(cat "$sudoers_source")" == 'agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v4-start-data-plane ""' ]] || fail 'V4 sudoers rule is not exact zero-argument authority'
[[ "$(wc -l <"$sudoers_source")" -eq 1 ]] || fail 'V4 sudoers contains unexpected extra rules'
printf 'V4_TEST_COUNT=%s\n' "$passes"
