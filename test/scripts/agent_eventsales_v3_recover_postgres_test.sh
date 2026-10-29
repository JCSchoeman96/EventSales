#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
wrapper_source="$repo_root/deploy/vps/operator/agent-eventsales-v3-recover-postgres"
old_provision="$repo_root/deploy/vps/operator/agent-eventsales-v3-provision-networks"
old_start="$repo_root/deploy/vps/operator/agent-eventsales-v3-start-postgres"
old_bootstrap="$repo_root/deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres"
old_sudoers="$repo_root/deploy/vps/operator/agent-eventsales-v3.sudoers"
audit_sudoers="$repo_root/deploy/vps/operator/agent-eventsales-v3-audit-state.sudoers"
compose_source="$repo_root/deploy/vps/data-plane/compose.yaml"
fixture_uid=$(id -u)
fixture_gid=$(id -g)
passes=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }

[[ -f "$wrapper_source" && ! -L "$wrapper_source" ]] || fail 'recovery wrapper source is missing'
[[ -f "$compose_source" ]] || fail 'corrected Compose source is missing'

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/eventsales-v3-recovery.XXXXXX")
fixture="$tmp_root/fixture"
root_fixture="$fixture/root"
fixture_bin="$fixture/bin"
hostile_python_dir="$fixture/hostile-python"
hostile_python_sentinel="$fixture/hostile-json-imported"
run_fixture="$fixture/run"
secret_fixture="$root_fixture/eventsales-prod/secrets-v1"
stage_fixture="$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane"
volume_fixture="$fixture/volume-a"
volume_alt_fixture="$fixture/volume-b"
state_file="$fixture/state"
docker_log="$fixture/docker.log"
out="$fixture/stdout"
err="$fixture/stderr"
wrapper_fixture="$tmp_root/recover-postgres"
base_pg_id=$(printf 'a%.0s' {1..64})
new_pg_id=$(printf 'b%.0s' {1..64})
d0_one=$(printf '1%.0s' {1..64})
d0_two=$(printf '2%.0s' {1..64})
d0_three=$(printf '3%.0s' {1..64})
data_network_id=$(printf '4%.0s' {1..64})
edge_network_id=$(printf '5%.0s' {1..64})

cleanup() { chmod -R u+w "$tmp_root" 2>/dev/null || true; rm -rf -- "$tmp_root"; }
trap cleanup EXIT
mkdir -p "$fixture_bin"
mkdir -p "$hostile_python_dir"
cat >"$hostile_python_dir/json.py" <<PYTHON
with open("$hostile_python_sentinel", "w", encoding="utf-8") as sentinel:
    sentinel.write("hostile json module imported")

def loads(_value):
    raise RuntimeError("attacker controlled JSON parser")
PYTHON

write_state() {
  cat >"$state_file" <<STATE
PG_PRESENT=yes
PG_KIND=failed
PG_ID=$base_pg_id
PG_STATUS=exited
PG_RUNNING=false
PG_RESTARTING=false
PG_EXIT=1
PG_RESTARTS=24
PG_OOM=false
PG_IMAGE=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
PG_MEMORY=3221225472
PG_NANO=2000000000
PG_COMMAND=failed
PG_HEALTH=none
INSPECT_FAIL_NEW=no
NEW_INSPECT_COUNT=0
NEW_NETWORK_DRIFT_AFTER_INSPECT=0
PG_PORTS={}
PG_MOUNTS=valid
PG_NETWORKS=valid
PG_INSPECT_COUNT=0
PG_DRIFT_AFTER_FIRST_INSPECT=no
EXTRA_PROD=no
EXTRA_AFTER_COMPOSE=no
DUPLICATE_POSTGRES_AFTER_COMPOSE=no
RM_FAIL=no
COMPOSE_FAIL=no
COMPOSE_CREATES=yes
NEW_ID=$new_pg_id
NEW_NAME=eventsales-prod-postgres-1
NEW_IMAGE=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
NEW_MEMORY=3221225472
NEW_NANO=2000000000
NEW_COMMAND=flags
NEW_MOUNTS=valid
NEW_NETWORKS=valid
NEW_PORTS={}
NEW_RESTARTS=0
NEW_OOM=false
NEW_HEALTH=healthy
NEW_STATUS=running
NEW_RUNNING=true
NEW_RESTARTING=false
STOP_FAIL=no
STOP_STILL_RUNNING=no
VOLUME_PRESENT=yes
VOLUME_NAME=eventsales-prod_postgres_data
VOLUME_DRIVER=local
VOLUME_SCOPE=local
VOLUME_PATH=$volume_fixture
VOLUME_INSPECT_COUNT=0
VOLUME_DRIFT_AFTER_FIRST_INSPECT=no
VOLUME_CHANGE_ON_RM=no
VOLUME_CHANGE_ON_COMPOSE=no
DATA_NETWORK_DRIVER=bridge
DATA_NETWORK_INTERNAL=true
DATA_NETWORK_ID=$data_network_id
EDGE_NETWORK_DRIVER=bridge
EDGE_NETWORK_INTERNAL=false
EDGE_NETWORK_ID=$edge_network_id
D0_ROWS=$d0_one|d0-one,$d0_two|d0-two,$d0_three|d0-three
D0_STATUS=exited
D0_RUNNING=false
D0_RESTARTING=false
D0_CHANGE_AFTER_COMPOSE=no
NETWORK_CHANGE_AFTER_COMPOSE=no
STAT_OVERRIDE_PATH=none
STAT_OVERRIDE=none
MARKER_MKDIR_FAIL=no
OVERRIDE_CHMOD_FAIL=no
OVERRIDE_DIRECTORY_METADATA_BAD=no
OVERRIDE_FILE_METADATA_BAD=no
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
  rm -rf -- "$root_fixture" "$run_fixture" "$volume_fixture" "$volume_alt_fixture"
  mkdir -p "$stage_fixture" "$secret_fixture" "$run_fixture" "$volume_fixture" "$volume_alt_fixture" "$fixture_bin"
  cp -- "$compose_source" "$stage_fixture/compose.yaml"
  chmod 0444 "$stage_fixture/compose.yaml"
  for name in postgres_bootstrap_password eventsales_migrator_password eventsales_runtime_server_password \
    eventsales_runtime_client_password eventsales_backup_password redis_runtime_password redis_stats_password; do
    head -c 64 /dev/zero >"$secret_fixture/$name"
    if [[ "$name" == postgres_bootstrap_password ]]; then chmod 0440 "$secret_fixture/$name"; else chmod 0400 "$secret_fixture/$name"; fi
  done
  for name in pgbouncer.ini pgbouncer_users.txt redis-users.acl; do
    printf 'safe fixture\n' >"$secret_fixture/$name"
    chmod 0440 "$secret_fixture/$name"
  done
  chmod 0700 "$secret_fixture"
  chmod 0755 "$root_fixture/eventsales-prod"
  chmod 0755 "$root_fixture/eventsales-prod/staged"
  chmod 0755 "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107"
  chmod 0755 "$stage_fixture"
  chmod 0755 "$run_fixture"
}

cat >"$fixture_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
log='FIXTURE_LOG'
get() { /usr/bin/awk -F= -v key="$1" '$1==key{sub(/^[^=]*=/,"");print;exit}' "$state"; }
setv() { /usr/bin/awk -F= -v key="$1" -v value="$2" 'BEGIN{f=0}$1==key{print key "=" value;f=1;next}{print}END{if(!f)print key "=" value}' "$state" >"$state.tmp"; /usr/bin/mv "$state.tmp" "$state"; }
printf 'ENV|host=%s|context=%s|config=%s|path=%s|project=%s|secret=%s|compose_file=%s|bash_env=%s\n' \
  "${DOCKER_HOST-}" "${DOCKER_CONTEXT-}" "${DOCKER_CONFIG-}" "${PATH-}" "${COMPOSE_PROJECT_NAME-}" \
  "${EVENTSALES_SECRET_DIR-}" "${COMPOSE_FILE-}" "${BASH_ENV-}" >>"$log"
printf 'CALL|%s\n' "$*" >>"$log"
command=${1-}
case "$command" in
  ps)
    if [[ "$*" == *eventsales-d0-proof* ]]; then
      /usr/bin/tr ',' '\n' <<<"$(get D0_ROWS)"
    elif [[ "$*" == *'filter id='* ]]; then
      filter_id=${5#id=}
      [[ "$(get PG_PRESENT)" == yes && "$filter_id" == "$(get PG_ID)" ]] && printf '%s\n' "$filter_id"
    elif [[ "$(get PG_PRESENT)" == yes ]]; then
      printf '%s|%s\n' "$(get PG_ID)" eventsales-prod-postgres-1
      if [[ "$(get EXTRA_PROD)" == yes ]]; then printf '%s|%s\n' "$(printf 'c%.0s' {1..64})" eventsales-prod-extra; fi
      if [[ "$(get PG_KIND)" == new && "$(get DUPLICATE_POSTGRES_AFTER_COMPOSE)" == yes ]]; then printf '%s|%s\n' "$(printf 'd%.0s' {1..64})" eventsales-prod-postgres-1; fi
    elif [[ "$(get EXTRA_PROD)" == yes ]]; then
      printf '%s|%s\n' "$(printf 'c%.0s' {1..64})" eventsales-prod-extra
    fi
    ;;
  inspect)
    format=${3-}
    id=${4-}
    if [[ "$format" == '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Running}}|{{.State.Restarting}}' ]]; then
      if [[ "$id" == "$(get D0_ROWS | /usr/bin/cut -d'|' -f1)" || "$id" == "$(get D0_ROWS | /usr/bin/cut -d',' -f2 | /usr/bin/cut -d'|' -f1)" || "$id" == "$(get D0_ROWS | /usr/bin/cut -d',' -f3 | /usr/bin/cut -d'|' -f1)" ]]; then
        name=d0-one
        [[ "$id" == "$(get D0_ROWS | /usr/bin/cut -d',' -f2 | /usr/bin/cut -d'|' -f1)" ]] && name=d0-two
        [[ "$id" == "$(get D0_ROWS | /usr/bin/cut -d',' -f3 | /usr/bin/cut -d'|' -f1)" ]] && name=d0-three
        printf '%s|/%s|%s|%s|%s\n' "$id" "$name" "$(get D0_STATUS)" "$(get D0_RUNNING)" "$(get D0_RESTARTING)"
      elif [[ "$(get PG_PRESENT)" == yes && "$id" == "$(get PG_ID)" ]]; then
        if [[ "$(get PG_KIND)" == failed ]]; then
          command_json='["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
        else
          command_json='["-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
        fi
        [[ "$(get PG_COMMAND)" != wrong ]] || command_json='["wrong"]'
        [[ "$(get PG_COMMAND)" != leading_postgres ]] || command_json='["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
        printf '%s|/eventsales-prod-postgres-1|%s|%s|%s\n' "$id" "$(get PG_STATUS)" "$(get PG_RUNNING)" "$(get PG_RESTARTING)"
      else exit 1
      fi
    elif [[ "$(get PG_PRESENT)" == yes && "$id" == "$(get PG_ID)" ]]; then
      if [[ "$(get PG_KIND)" == new && "$(get INSPECT_FAIL_NEW)" == yes ]]; then exit 1; fi
      if [[ "$(get PG_KIND)" == new ]]; then
        new_inspect_count=$(( $(get NEW_INSPECT_COUNT) + 1 ))
        setv NEW_INSPECT_COUNT "$new_inspect_count"
        if ((new_inspect_count >= $(get NEW_NETWORK_DRIFT_AFTER_INSPECT))); then
          [[ "$(get NEW_NETWORK_DRIFT_AFTER_INSPECT)" -gt 0 ]] && setv PG_NETWORKS bad
        fi
      fi
      if [[ "$(get PG_KIND)" == failed ]]; then
        inspect_count=$(( $(get PG_INSPECT_COUNT) + 1 ))
        setv PG_INSPECT_COUNT "$inspect_count"
        if [[ "$(get PG_DRIFT_AFTER_FIRST_INSPECT)" == yes && "$inspect_count" -ge 2 ]]; then setv PG_IMAGE wrong; fi
      fi
      if [[ "$(get PG_KIND)" == failed ]]; then
        command_json='["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
      else
        command_json='["-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
      fi
      [[ "$(get PG_COMMAND)" != wrong ]] || command_json='["wrong"]'
      [[ "$(get PG_COMMAND)" != leading_postgres ]] || command_json='["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]'
      mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"FIXTURE_SECRET_SOURCE/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]'
      networks='{"eventsales-prod_eventsales_data":{}}'
      ports='{}'
      [[ "$(get PG_MOUNTS)" == bad ]] && mounts='[]'
      [[ "$(get PG_MOUNTS)" == malformed_json ]] && mounts='[not-json'
      [[ "$(get PG_MOUNTS)" == wrong_volume ]] && mounts='[{"Type":"volume","Name":"other_volume","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"FIXTURE_SECRET_SOURCE/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]'
      [[ "$(get PG_MOUNTS)" == wrong_destination ]] && mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/wrong"},{"Type":"bind","Source":"FIXTURE_SECRET_SOURCE/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false}]'
      [[ "$(get PG_MOUNTS)" == extra ]] && mounts='[{"Type":"volume","Name":"eventsales-prod_postgres_data","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"FIXTURE_SECRET_SOURCE/postgres_bootstrap_password","Destination":"/run/secrets/postgres_bootstrap_password","RW":false},{"Type":"bind","Source":"/other","Destination":"/other","RW":false}]'
      [[ "$(get PG_NETWORKS)" == bad ]] && networks='{}'
      [[ "$(get PG_PORTS)" != '{}' ]] && ports='{"5432/tcp":[{"HostPort":"5432"}]}'
      [[ "$(get PG_PORTS)" == malformed ]] && ports='{}'
      printf '%s|/eventsales-prod-postgres-1|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$id" "$(get PG_STATUS)" "$(get PG_RUNNING)" "$(get PG_RESTARTING)" "$(get PG_EXIT)" \
        "$(get PG_RESTARTS)" "$(get PG_OOM)" "$(get PG_IMAGE)" "$(get PG_MEMORY)" "$(get PG_NANO)" \
        "$command_json" "$mounts" "$networks" "$ports" "$(get PG_HEALTH)"
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
    volume_inspect_count=$(( $(get VOLUME_INSPECT_COUNT) + 1 ))
    setv VOLUME_INSPECT_COUNT "$volume_inspect_count"
    if [[ "$(get VOLUME_DRIFT_AFTER_FIRST_INSPECT)" == yes && "$volume_inspect_count" -ge 2 ]]; then setv VOLUME_PATH 'FIXTURE_VOLUME_ALT'; fi
    printf '%s|%s|%s|%s\n' "$(get VOLUME_NAME)" "$(get VOLUME_DRIVER)" "$(get VOLUME_SCOPE)" "$(get VOLUME_PATH)"
    ;;
  rm)
    [[ "$(get RM_FAIL)" == no ]] || exit 1
    [[ "$2" == "$(get PG_ID)" ]] || exit 90
    setv PG_PRESENT no
    if [[ "$(get VOLUME_CHANGE_ON_RM)" == missing ]]; then setv VOLUME_PRESENT no; fi
    if [[ "$(get VOLUME_CHANGE_ON_RM)" == fingerprint ]]; then setv VOLUME_PATH 'FIXTURE_VOLUME_ALT'; fi
    ;;
  compose)
    [[ $# -eq 13 && "$2" == --project-name && "$3" == eventsales-prod && "$4" == --env-file \
      && "$5" == /dev/null && "$6" == -f && "$7" == *'/data-plane/compose.yaml' \
      && "$8" == -f && "${10}" == up && "${11}" == -d && "${12}" == --no-deps && "${13}" == postgres ]] || exit 89
    override=$9
    [[ ! -L "$override" && -f "$override" && "$(/usr/bin/stat -c '%a' "$override")" == 400 \
      && "$(/usr/bin/stat -c '%a' "${override%/*}")" == 700 \
      && "$(stat -c '%u:%g:%a' "$override")" == 'FIXTURE_UID:FIXTURE_GID:400' \
      && "$(stat -c '%u:%g:%a' "${override%/*}")" == 'FIXTURE_UID:FIXTURE_GID:700' \
      && "$(/usr/bin/sha256sum "$override" | /usr/bin/awk '{print $1}')" == cc4bc2cee5847d9d24984ccc5521ef81868aeb77456e66b94df62c50685f2e14 ]] || exit 88
    [[ "$(/usr/bin/cat "$override")"$'\n' == $'volumes:\n  postgres_data:\n    external: true\n    name: eventsales-prod_postgres_data\n' ]] || exit 87
    if [[ "$(get COMPOSE_CREATES)" != yes ]]; then [[ "$(get COMPOSE_FAIL)" == no ]] && exit 0 || exit 1; fi
    setv PG_PRESENT yes
    setv PG_KIND new
    setv PG_ID "$(get NEW_ID)"
    setv PG_STATUS "$(get NEW_STATUS)"
    setv PG_RUNNING "$(get NEW_RUNNING)"
    setv PG_RESTARTING "$(get NEW_RESTARTING)"
    setv PG_EXIT 0
    setv PG_RESTARTS "$(get NEW_RESTARTS)"
    setv PG_OOM "$(get NEW_OOM)"
    setv PG_IMAGE "$(get NEW_IMAGE)"
    setv PG_MEMORY "$(get NEW_MEMORY)"
    setv PG_NANO "$(get NEW_NANO)"
    setv PG_COMMAND "$(get NEW_COMMAND)"
    setv PG_MOUNTS "$(get NEW_MOUNTS)"
    setv PG_NETWORKS "$(get NEW_NETWORKS)"
    setv PG_PORTS "$(get NEW_PORTS)"
    setv PG_HEALTH "$(get NEW_HEALTH)"
    setv EXTRA_PROD "$(get EXTRA_AFTER_COMPOSE)"
    if [[ "$(get D0_CHANGE_AFTER_COMPOSE)" == yes ]]; then setv D0_RUNNING true; fi
    if [[ "$(get D0_CHANGE_AFTER_COMPOSE)" == identity ]]; then setv D0_ROWS '6666666666666666666666666666666666666666666666666666666666666666|d0-new,2222222222222222222222222222222222222222222222222222222222222222|d0-two,3333333333333333333333333333333333333333333333333333333333333333|d0-three'; fi
    if [[ "$(get D0_CHANGE_AFTER_COMPOSE)" == count ]]; then setv D0_ROWS '1111111111111111111111111111111111111111111111111111111111111111|d0-one,2222222222222222222222222222222222222222222222222222222222222222|d0-two'; fi
    if [[ "$(get VOLUME_CHANGE_ON_COMPOSE)" == fingerprint ]]; then setv VOLUME_PATH 'FIXTURE_VOLUME_ALT'; fi
    if [[ "$(get NETWORK_CHANGE_AFTER_COMPOSE)" == yes ]]; then setv DATA_NETWORK_ID '7777777777777777777777777777777777777777777777777777777777777777'; fi
    [[ "$(get COMPOSE_FAIL)" == no ]] || exit 1
    ;;
  stop)
    [[ "$2" == --time && "$3" == 10 && "$4" == "$(get NEW_ID)" ]] || exit 91
    [[ "$(get STOP_FAIL)" == no ]] || exit 1
    [[ "$(get STOP_STILL_RUNNING)" == yes ]] || { setv PG_RUNNING false; setv PG_RESTARTING false; setv PG_STATUS exited; }
    ;;
  *) exit 92 ;;
esac
DOCKER
chmod 0755 "$fixture_bin/docker"

cat >"$fixture_bin/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
target=${@: -1}
format=${2-}
override_path=$(/usr/bin/awk -F= '$1=="STAT_OVERRIDE_PATH"{sub(/^[^=]*=/,"");print;exit}' "$state")
override=$(/usr/bin/awk -F= '$1=="STAT_OVERRIDE"{sub(/^[^=]*=/,"");print;exit}' "$state")
if [[ "$target" == "$override_path" && "$override" != none ]]; then printf '%s\n' "$override"; exit 0; fi
override_dir_bad=$(/usr/bin/awk -F= '$1=="OVERRIDE_DIRECTORY_METADATA_BAD"{sub(/^[^=]*=/,"");print;exit}' "$state")
override_file_bad=$(/usr/bin/awk -F= '$1=="OVERRIDE_FILE_METADATA_BAD"{sub(/^[^=]*=/,"");print;exit}' "$state")
if [[ "$format" == '%u:%g:%a' && "$target" == */.v3-postgres-recovery.* && "$override_dir_bad" == yes ]]; then printf '65534:65534:777\n'; exit 0; fi
if [[ "$format" == '%u:%g:%a' && "$target" == */compose.override.yaml && "$override_file_bad" == yes ]]; then printf '65534:65534:444\n'; exit 0; fi
if [[ "$format" == '%u:%g:%a' || "$format" == '%u:%g:%a:%s' ]]; then
  actual=$(/usr/bin/stat -c "$format" -- "$target")
  IFS=: read -r uid gid mode size <<<"$actual"
  if [[ "$target" == *'/secrets-v1/'* ]]; then
    uid=0
    case "$target" in
      */postgres_bootstrap_password) gid=70 ;;
      */pgbouncer.ini|*/pgbouncer_users.txt|*/redis-users.acl) gid=65532 ;;
      *) gid=0 ;;
    esac
  else
    uid='FIXTURE_UID'; gid='FIXTURE_GID'
  fi
  if [[ "$format" == '%u:%g:%a' ]]; then printf '%s:%s:%s\n' "$uid" "$gid" "$mode"; else printf '%s:%s:%s:%s\n' "$uid" "$gid" "$mode" "$size"; fi
else /usr/bin/stat "$@"
fi
STAT
chmod 0755 "$fixture_bin/stat"

cat >"$fixture_bin/mkdir" <<'MKDIR'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
fail=$(/usr/bin/awk -F= '$1=="MARKER_MKDIR_FAIL"{sub(/^[^=]*=/,"");print;exit}' "$state")
target=${@: -1}
if [[ "$fail" == yes && "$target" == *'.v3-postgres-recovery-consumed' ]]; then exit 1; fi
exec /usr/bin/mkdir "$@"
MKDIR
chmod 0755 "$fixture_bin/mkdir"

cat >"$fixture_bin/chmod" <<'CHMOD'
#!/usr/bin/env bash
set -euo pipefail
state='FIXTURE_STATE'
target=${@: -1}
fail=$(/usr/bin/awk -F= '$1=="OVERRIDE_CHMOD_FAIL"{sub(/^[^=]*=/,"");print;exit}' "$state")
if [[ "$fail" == yes && "$target" == */compose.override.yaml ]]; then exit 1; fi
exec /usr/bin/chmod "$@"
CHMOD
chmod 0755 "$fixture_bin/chmod"

render_test_wrapper() {
    /usr/bin/sed \
    -e "s|/root|$root_fixture|g" \
    -e "s|readonly SAFE_PATH='/usr/sbin:/usr/bin:/sbin:/bin'|readonly SAFE_PATH='$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin'|" \
    -e "s|readonly RUN_DIR='/run'|readonly RUN_DIR='$run_fixture'|" \
    -e "s|readonly LOCK_FILE='/run/agent-eventsales-v3-recover-postgres.lock'|readonly LOCK_FILE='$run_fixture/agent-eventsales-v3-recover-postgres.lock'|" \
    -e "s|readonly ROOT_UID='0'|readonly ROOT_UID='$fixture_uid'|" \
    -e "s|readonly ROOT_GID='0'|readonly ROOT_GID='$fixture_gid'|" \
    -e "s|readonly HEALTH_TIMEOUT=120|readonly HEALTH_TIMEOUT=1|" \
    -e "s|readonly HEALTH_INTERVAL=2|readonly HEALTH_INTERVAL=1|" \
    -e 's/((EUID != ROOT_UID))/((TEST_EUID != ROOT_UID))/' \
    "$wrapper_source" >"$wrapper_fixture"
  chmod 0755 "$wrapper_fixture"
  /usr/bin/sed \
    -e "s|FIXTURE_STATE|$state_file|g" \
    -e "s|FIXTURE_LOG|$docker_log|g" \
    -e "s|FIXTURE_VOLUME_ALT|$volume_alt_fixture|g" \
    -e "s|FIXTURE_SECRET_SOURCE|$secret_fixture|g" \
    -e "s|FIXTURE_UID|$fixture_uid|g" \
    -e "s|FIXTURE_GID|$fixture_gid|g" \
    "$fixture_bin/docker" >"$fixture_bin/docker.tmp"
  /usr/bin/mv "$fixture_bin/docker.tmp" "$fixture_bin/docker"
  chmod 0755 "$fixture_bin/docker"
  /usr/bin/sed -e "s|FIXTURE_STATE|$state_file|g" -e "s|FIXTURE_UID|$fixture_uid|g" \
    -e "s|FIXTURE_GID|$fixture_gid|g" "$fixture_bin/stat" >"$fixture_bin/stat.tmp"
  /usr/bin/mv "$fixture_bin/stat.tmp" "$fixture_bin/stat"
  chmod 0755 "$fixture_bin/stat"
  /usr/bin/sed -e "s|FIXTURE_STATE|$state_file|g" "$fixture_bin/mkdir" >"$fixture_bin/mkdir.tmp"
  /usr/bin/mv "$fixture_bin/mkdir.tmp" "$fixture_bin/mkdir"
  chmod 0755 "$fixture_bin/mkdir"
  /usr/bin/sed -e "s|FIXTURE_STATE|$state_file|g" "$fixture_bin/chmod" >"$fixture_bin/chmod.tmp"
  /usr/bin/mv "$fixture_bin/chmod.tmp" "$fixture_bin/chmod"
  chmod 0755 "$fixture_bin/chmod"
}

reset_case() { make_filesystem; write_state; render_test_wrapper; }

run_wrapper() {
  local pythonpath=${1:-}
  env TEST_EUID="$fixture_uid" PATH="$fixture_bin:/usr/bin:/bin" PYTHONPATH="$pythonpath" \
    DOCKER_HOST='tcp://attacker.invalid:2375' DOCKER_CONTEXT='caller-context' \
    DOCKER_CONFIG='/caller/docker-config' COMPOSE_PROJECT_NAME='caller-project' \
    COMPOSE_FILE='/caller/compose.yaml' EVENTSALES_SECRET_DIR='/caller/secrets' \
    BASH_ENV='caller-bash-env' ENV='caller-env' CDPATH='/caller/cdpath' \
    "$wrapper_fixture" >"$out" 2>"$err"
}

call_count() { /usr/bin/grep -c "^CALL|$1" "$docker_log" || true; }
assert_no_mutations() {
  [[ "$(call_count 'rm ')" -eq 0 && "$(call_count 'compose ')" -eq 0 && "$(call_count 'stop ')" -eq 0 ]] || fail "$1 called an unauthorized mutation"
  ! /usr/bin/grep -Eq '^CALL\|(volume (rm|create|prune)|network (create|rm|connect|disconnect)|system (prune|prune))' "$docker_log" || fail "$1 mutated volume/network/D0 state"
}
expect_stop() {
  local label=$1 expected=$2 status
  set +e; run_wrapper; status=$?; set -e
  ((status != 0)) || fail "$label unexpectedly succeeded"
  /usr/bin/grep -Fxq "STOP=$expected" "$err" || { cat "$err" >&2; fail "$label stopped for the wrong reason"; }
  assert_no_mutations "$label"
  pass "$label"
}

reset_case
set +e; env TEST_EUID="$fixture_uid" "$wrapper_fixture" argument >"$out" 2>"$err"; status=$?; set -e
if ((status == 0)) || ! /usr/bin/grep -Fxq 'STOP=CALLER_ARGUMENTS_FORBIDDEN' "$err"; then fail 'caller arguments were not rejected'; fi
assert_no_mutations arguments
pass 'rejects caller arguments before Docker'

reset_case
set +e; env TEST_EUID=65534 "$wrapper_fixture" >"$out" 2>"$err"; status=$?; set -e
if ((status == 0)) || ! /usr/bin/grep -Fxq 'STOP=ROOT_REQUIRED' "$err"; then fail 'non-root invocation was not rejected'; fi
assert_no_mutations non-root
pass 'rejects non-root invocation'

reset_case
hash -r
/usr/bin/chmod 0777 "$run_fixture"
expect_stop 'unsafe /run permissions' RUN_DIRECTORY_WRITABLE
reset_case
set_state STAT_OVERRIDE_PATH "$run_fixture"
set_state STAT_OVERRIDE '65534:65534:755'
expect_stop 'unsafe /run ownership' RUN_DIRECTORY_OWNER_MISMATCH
reset_case
ln -s "$fixture/not-a-lock" "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
expect_stop 'lock symlink' LOCK_SYMLINK
reset_case
touch "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
set_state STAT_OVERRIDE_PATH "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
set_state STAT_OVERRIDE "$fixture_uid:$fixture_gid:644"
expect_stop 'lock mode mismatch' LOCK_METADATA_MISMATCH
reset_case
mkdir "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
expect_stop 'lock directory conflict' LOCK_FILE_INVALID
reset_case
touch "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
set_state STAT_OVERRIDE_PATH "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
set_state STAT_OVERRIDE '65534:65534:600'
expect_stop 'lock owner mismatch' LOCK_METADATA_MISMATCH
reset_case
touch "$run_fixture/agent-eventsales-v3-recover-postgres.lock"
exec 8<>"$run_fixture/agent-eventsales-v3-recover-postgres.lock"
flock -n 8
expect_stop 'busy lock' LOCK_BUSY
exec 8>&-

for marker_kind in directory file symlink; do
  reset_case
  marker="$root_fixture/eventsales-prod/.v3-postgres-recovery-consumed"
  case "$marker_kind" in directory) mkdir "$marker" ;; file) touch "$marker" ;; symlink) ln -s "$fixture/target" "$marker" ;; esac
  expect_stop "consumed marker $marker_kind" RECOVERY_AUTHORITY_ALREADY_CONSUMED
done
reset_case
set_state MARKER_MKDIR_FAIL yes
expect_stop 'marker creation failure' RECOVERY_MARKER_CREATE_FAILED
reset_case
chmod 0555 "$root_fixture/eventsales-prod"
expect_stop 'override directory creation failure' OVERRIDE_DIRECTORY_CREATE_FAILED
reset_case
set_state OVERRIDE_CHMOD_FAIL yes
expect_stop 'override file mode failure' OVERRIDE_MODE_MISMATCH
reset_case
set_state OVERRIDE_DIRECTORY_METADATA_BAD yes
expect_stop 'override directory metadata failure' OVERRIDE_DIRECTORY_METADATA_MISMATCH
reset_case
set_state OVERRIDE_FILE_METADATA_BAD yes
expect_stop 'override file metadata failure' OVERRIDE_METADATA_MISMATCH

reset_case
chmod u+w "$root_fixture/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107"
rm -rf "$stage_fixture"
ln -s "$fixture/elsewhere" "$stage_fixture"
expect_stop 'immutable stage symlink' IMMUTABLE_STAGE_DIRECTORY_SYMLINK
reset_case
set_state STAT_OVERRIDE_PATH "$stage_fixture"
set_state STAT_OVERRIDE '65534:65534:755'
expect_stop 'immutable stage owner drift' IMMUTABLE_STAGE_DIRECTORY_OWNER_MISMATCH
reset_case
chmod 0775 "$stage_fixture"
expect_stop 'immutable stage writable' IMMUTABLE_STAGE_DIRECTORY_WRITABLE
reset_case
rm "$stage_fixture/compose.yaml"; ln -s "$fixture/compose" "$stage_fixture/compose.yaml"
expect_stop 'Compose symlink' IMMUTABLE_COMPOSE_SYMLINK
reset_case
rm "$stage_fixture/compose.yaml"; mkdir "$stage_fixture/compose.yaml"
expect_stop 'Compose non-regular type' IMMUTABLE_COMPOSE_NOT_REGULAR
reset_case
set_state STAT_OVERRIDE_PATH "$stage_fixture/compose.yaml"
set_state STAT_OVERRIDE '65534:65534:444'
expect_stop 'Compose owner drift' IMMUTABLE_COMPOSE_OWNER_MISMATCH
reset_case
chmod 0644 "$stage_fixture/compose.yaml"
expect_stop 'Compose writable' IMMUTABLE_COMPOSE_WRITABLE
reset_case
chmod u+w "$stage_fixture/compose.yaml"
printf 'changed bytes\n' >"$stage_fixture/compose.yaml"; chmod 0444 "$stage_fixture/compose.yaml"
expect_stop 'Compose hash mismatch' COMPOSE_HASH_MISMATCH

reset_case
chmod 0755 "$secret_fixture"
expect_stop 'secret directory mode mismatch' SECRET_DIRECTORY_METADATA_MISMATCH
reset_case
set_state STAT_OVERRIDE_PATH "$secret_fixture/postgres_bootstrap_password"
set_state STAT_OVERRIDE '0:70:600:64'
expect_stop 'bootstrap secret metadata mismatch' SECRET_FILE_METADATA_MISMATCH
for secret_name in eventsales_migrator_password eventsales_runtime_server_password eventsales_runtime_client_password \
  eventsales_backup_password redis_runtime_password redis_stats_password pgbouncer.ini pgbouncer_users.txt redis-users.acl; do
  reset_case
  set_state STAT_OVERRIDE_PATH "$secret_fixture/$secret_name"
  set_state STAT_OVERRIDE '1:1:400:64'
  expect_stop "secret metadata drift: $secret_name" SECRET_FILE_METADATA_MISMATCH
done

reset_case
set_state DATA_NETWORK_INTERNAL false
expect_stop 'data network identity drift' DATA_NETWORK_IDENTITY_MISMATCH
reset_case
set_state DATA_NETWORK_ID invalid
expect_stop 'data network ID format mismatch' DATA_NETWORK_IDENTITY_MISMATCH
reset_case
set_state EDGE_NETWORK_DRIVER overlay
expect_stop 'edge network identity drift' EDGE_NETWORK_IDENTITY_MISMATCH
reset_case
set_state EDGE_NETWORK_INTERNAL true
expect_stop 'edge network internal flag drift' EDGE_NETWORK_IDENTITY_MISMATCH
reset_case
set_state VOLUME_PRESENT no
expect_stop 'missing PostgreSQL volume' POSTGRES_VOLUME_IDENTITY_MISMATCH
reset_case
set_state VOLUME_NAME other-volume
expect_stop 'PostgreSQL volume name drift' POSTGRES_VOLUME_IDENTITY_MISMATCH
reset_case
set_state VOLUME_DRIVER nfs
expect_stop 'PostgreSQL volume driver drift' POSTGRES_VOLUME_IDENTITY_MISMATCH
reset_case
set_state VOLUME_SCOPE global
expect_stop 'PostgreSQL volume scope drift' POSTGRES_VOLUME_IDENTITY_MISMATCH
reset_case
set_state VOLUME_PATH "$fixture/missing-volume-mountpoint"
expect_stop 'PostgreSQL volume mountpoint missing' POSTGRES_VOLUME_IDENTITY_MISMATCH
reset_case
set_state VOLUME_DRIFT_AFTER_FIRST_INSPECT yes
expect_stop 'pre-removal volume fingerprint drift' PRE_REMOVE_VOLUME_FINGERPRINT_CHANGED

reset_case
set_state EXTRA_PROD yes
expect_stop 'unexpected production container' UNEXPECTED_PRODUCTION_CONTAINER
reset_case
set_state PG_RUNNING true
set_state PG_STATUS running
expect_stop 'failed PostgreSQL running' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_RESTARTING true
expect_stop 'failed PostgreSQL restarting' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_EXIT 2
expect_stop 'failed PostgreSQL exit code drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_RESTARTS 23
expect_stop 'failed PostgreSQL restart count drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_OOM true
expect_stop 'failed PostgreSQL OOM drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_IMAGE wrong/image
expect_stop 'failed PostgreSQL image drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_MEMORY 1
expect_stop 'failed PostgreSQL resource drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_COMMAND wrong
expect_stop 'failed PostgreSQL command drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_ID invalid
expect_stop 'failed PostgreSQL ID format drift' FAILED_CONTAINER_ID_INVALID
reset_case
set_state PG_DRIFT_AFTER_FIRST_INSPECT yes
expect_stop 'failed PostgreSQL reinspection drift' FAILED_CONTAINER_REINSPECTION_DRIFT
reset_case
set_state PG_PRESENT no
expect_stop 'missing failed PostgreSQL container' POSTGRES_CONTAINER_MISSING
reset_case
set_state PG_MOUNTS bad
expect_stop 'failed PostgreSQL volume/secret mount drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_MOUNTS wrong_volume
expect_stop 'failed PostgreSQL wrong volume identity' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_MOUNTS wrong_destination
expect_stop 'failed PostgreSQL wrong volume destination' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_MOUNTS extra
expect_stop 'failed PostgreSQL extra mount' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_NETWORKS bad
expect_stop 'failed PostgreSQL network drift' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state PG_PORTS published
expect_stop 'failed PostgreSQL published port' FAILED_CONTAINER_CONTRACT_MISMATCH
reset_case
set_state NEW_ID invalid
# This fixture also exercises validation of the ID returned by the post-compose inventory.
set_state D0_ROWS "$d0_one|d0-one,$d0_two|d0-two"
expect_stop 'D0 count mismatch' D0_CONTRACT_MISMATCH
reset_case
set_state D0_RUNNING true
expect_stop 'D0 running object' D0_CONTRACT_MISMATCH
reset_case
set_state D0_RESTARTING true
expect_stop 'D0 restarting object' D0_CONTRACT_MISMATCH
reset_case
set_state D0_ROWS "bad-id|d0-one,$d0_two|d0-two,$d0_three|d0-three"
expect_stop 'D0 ID format mismatch' D0_CONTRACT_MISMATCH

# A successful fake recovery proves the exact mutation boundary and safe output.
reset_case
set_state PG_MOUNTS malformed_json
set +e; run_wrapper; malformed_status=$?; set -e
((malformed_status != 0)) || fail 'malformed attachment data unexpectedly passed validation'
[[ "$(cat "$err")" == 'STOP=FAILED_CONTAINER_CONTRACT_MISMATCH' ]] || {
  cat "$err" >&2
  fail 'malformed attachment data did not produce deterministic safe output'
}
assert_no_mutations 'malformed attachment data'
pass 'malformed attachment JSON fails closed without interpreter diagnostics'

reset_case
set +e; run_wrapper "$hostile_python_dir"; hostile_python_status=$?; set -e
[[ ! -e "$hostile_python_sentinel" ]] || fail 'caller-controlled PYTHONPATH imported attacker json.py'
((hostile_python_status == 0)) || { cat "$err" >&2; fail 'valid fake recovery failed under hostile PYTHONPATH'; }
/usr/bin/grep -Fxq 'POSTGRES_RECOVERY=HEALTHY' "$out" || fail 'hostile PYTHONPATH recovery omitted its success result'
pass 'attachment validation ignores hostile Python module and still recovers'

reset_case
run_wrapper || { cat "$err" >&2; cat "$docker_log" >&2; fail 'valid fake recovery did not succeed'; }
[[ "$(call_count 'rm ')" -eq 1 ]] || fail 'failed container was not removed exactly once'
[[ "$(call_count 'compose ')" -eq 1 ]] || fail 'Compose was not invoked exactly once'
[[ "$(call_count 'stop ')" -eq 0 ]] || fail 'success path unexpectedly stopped PostgreSQL'
/usr/bin/grep -Fq "CALL|rm $base_pg_id" "$docker_log" || fail 'failed container was not removed by captured ID'
/usr/bin/grep -Fq 'compose --project-name eventsales-prod --env-file /dev/null' "$docker_log" || fail 'Compose project or env file contract mismatch'
/usr/bin/grep -Fq -- "-f $stage_fixture/compose.yaml -f " "$docker_log" || fail 'recovery override was not the second Compose file'
/usr/bin/grep -Fq 'CALL|ps -a --no-trunc --filter label=com.docker.compose.project=eventsales-prod' "$docker_log" || fail 'production listing did not request full container IDs'
override_hash=$(printf '%s' $'volumes:\n  postgres_data:\n    external: true\n    name: eventsales-prod_postgres_data\n' | sha256sum | awk '{print $1}')
[[ "$override_hash" == cc4bc2cee5847d9d24984ccc5521ef81868aeb77456e66b94df62c50685f2e14 ]] || fail 'literal external-volume override hash is wrong'
for required in \
  POSTGRES_RECOVERY=HEALTHY POSTGRES_STATUS=running POSTGRES_HEALTH=healthy \
  POSTGRES_RESTART_COUNT=0 POSTGRES_IMAGE_MATCH=YES POSTGRES_COMMAND_CLASS=CORRECTED_FLAGS_ONLY \
  POSTGRES_VOLUME_ATTACHMENT_MATCH=YES POSTGRES_NETWORK_ATTACHMENT_MATCH=YES POSTGRES_PORTS_PUBLISHED=NO \
  POSTGRES_VOLUME_PRESERVED=YES PGBOUNCER_STARTED=NO REDIS_STARTED=NO APP_STARTED=NO D0_STATE=ARCHIVED_STOPPED; do
  /usr/bin/grep -Fxq "$required" "$out" || fail "success output omitted $required"
done
if /usr/bin/grep -Eq 'caller|attacker\.invalid|/secrets-v1/postgres_bootstrap_password|/volume-|Config\.Env|\{[^}]*\}' "$out"; then fail 'success output leaked environment or Docker details'; fi
/usr/bin/grep -Fq 'ENV|host=unix:///var/run/docker.sock|' "$docker_log" || fail 'Docker socket was not fixed'
if /usr/bin/grep -Eq 'attacker\.invalid|caller-context|caller-project|caller/secrets|caller/docker-config|caller-bash-env' "$docker_log"; then fail 'caller environment reached Docker'; fi
pass 'success path uses captured ID, exact Compose override, and safe output'

post_failure_case() {
  local label=$1 expected=$2 state_key=$3 value=$4 stop_expected=$5 compose_expected=${6:-1} \
    extra_key=${7:-none} extra_value=${8:-} terminal_state=${9:-RECOVERY_FAILED_CONTAINED} stop_calls d0_before d0_after
  reset_case
  set_state COMPOSE_CREATES yes
  if [[ "$state_key" == PG_* ]]; then state_key="NEW_${state_key#PG_}"; fi
  [[ "$state_key" == none ]] || set_state "$state_key" "$value"
  [[ "$extra_key" == none ]] || set_state "$extra_key" "$extra_value"
  d0_before=$(/usr/bin/grep '^D0_' "$state_file")
  set +e; run_wrapper; status=$?; set -e
  ((status != 0)) || { cat "$state_file" >&2; cat "$docker_log" >&2; fail "$label unexpectedly succeeded"; }
  /usr/bin/grep -Fxq "STOP=$expected" "$err" || { cat "$err" >&2; fail "$label stopped for the wrong reason"; }
  /usr/bin/grep -Fxq "RECOVERY_STATE=$terminal_state" "$err" || fail "$label did not report its terminal state"
  [[ "$(call_count 'compose ')" -eq "$compose_expected" ]] || fail "$label used an unexpected number of Compose calls"
  [[ "$(call_count 'rm ')" -eq 1 ]] || fail "$label did not remove the failed container exactly once"
  /usr/bin/grep -Fq "CALL|rm $base_pg_id" "$docker_log" || fail "$label did not remove the captured failed ID"
  stop_calls=$(call_count 'stop ')
  [[ "$stop_calls" -eq "$stop_expected" ]] || fail "$label used $stop_calls containment stops"
  if ((stop_expected == 1)); then /usr/bin/grep -Fq "CALL|stop --time 10 $new_pg_id" "$docker_log" || fail "$label stopped the wrong ID"; fi
  [[ -d "$root_fixture/eventsales-prod/.v3-postgres-recovery-consumed" ]] || fail "$label cleared or lost the consumed marker"
  [[ "$(call_count "rm $new_pg_id")" -eq 0 ]] || fail "$label removed the recreated container"
  ! /usr/bin/grep -Eq '^CALL\|(volume (rm|create|prune)|network (create|rm|connect|disconnect)|system (prune|prune))' "$docker_log" || fail "$label mutated storage or networks"
  if [[ "$state_key" == COMPOSE_CREATES && "$value" == no ]]; then
    d0_after=$(printf '%s\n' "$(/usr/bin/grep '^D0_' "$state_file")")
    [[ "$d0_before" == "$d0_after" ]] || fail "$label changed D0 fixture state"
  fi
  pass "$label"
}

post_failure_case 'Compose success without recreated PostgreSQL' RECREATED_CONTAINER_MISSING COMPOSE_CREATES no 0 1
post_failure_case 'failed Compose without a recreated object is contained' COMPOSE_FAILED_NO_RECREATED_CONTAINER COMPOSE_CREATES no 0 1 COMPOSE_FAIL yes
post_failure_case 'Compose failure with running recreated object' COMPOSE_UP_FAILED COMPOSE_FAIL yes 1
post_failure_case 'invalid recreated ID remains uncontained without guessing' COMPOSE_RESULT_INVENTORY_AMBIGUOUS NEW_ID invalid 0 1 none '' RECOVERY_FAILED_UNCONTAINED
post_failure_case 'uninspectable recreated object remains uncontained' RECREATED_CONTAINER_CONTRACT_MISMATCH INSPECT_FAIL_NEW yes 0 1 none '' RECOVERY_FAILED_UNCONTAINED
post_failure_case 'reused failed ID remains uncontained' RECREATED_CONTAINER_ID_REUSED NEW_ID "$base_pg_id" 0 1 none '' RECOVERY_FAILED_UNCONTAINED
post_failure_case 'ambiguous duplicate PostgreSQL identity remains uncontained' COMPOSE_RESULT_INVENTORY_AMBIGUOUS DUPLICATE_POSTGRES_AFTER_COMPOSE yes 0 1 none '' RECOVERY_FAILED_UNCONTAINED
post_failure_case 'wrong recreated image is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_IMAGE wrong 1
post_failure_case 'wrong recreated command is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_COMMAND wrong 1
post_failure_case 'leading postgres command is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_COMMAND leading_postgres 1
post_failure_case 'published recreated port is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_PORTS published 1
post_failure_case 'wrong recreated mount is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_MOUNTS bad 1
post_failure_case 'wrong recreated network is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_NETWORKS bad 1
post_failure_case 'wrong recreated memory is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_MEMORY 1 1
post_failure_case 'wrong recreated CPU limit is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_NANO 1 1
post_failure_case 'restarted recreated object is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_RESTARTS 1 1
post_failure_case 'OOM recreated object is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_OOM true 1
post_failure_case 'unhealthy recreated object is contained' POSTGRES_HEALTH_UNHEALTHY PG_HEALTH unhealthy 1
post_failure_case 'health timeout contains running recreated object' POSTGRES_HEALTH_TIMEOUT PG_HEALTH starting 1
post_failure_case 'already stopped recreated failure skips stop' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_RUNNING false 0 1 NEW_STATUS exited
post_failure_case 'D0 drift after Compose is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH D0_CHANGE_AFTER_COMPOSE yes 1
post_failure_case 'D0 ID drift after Compose is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH D0_CHANGE_AFTER_COMPOSE identity 1
post_failure_case 'D0 count drift after Compose is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH D0_CHANGE_AFTER_COMPOSE count 1
post_failure_case 'extra production container after Compose is contained' PRODUCTION_INVENTORY_MISMATCH EXTRA_AFTER_COMPOSE yes 1
post_failure_case 'Compose-time volume disappearance blocks without replacement' POST_REMOVE_VOLUME_FINGERPRINT_CHANGED VOLUME_CHANGE_ON_RM missing 0 0
post_failure_case 'pre-Compose fingerprint drift blocks Compose' POST_REMOVE_VOLUME_FINGERPRINT_CHANGED VOLUME_CHANGE_ON_RM fingerprint 0 0
post_failure_case 'post-Compose fingerprint drift is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH VOLUME_CHANGE_ON_COMPOSE fingerprint 1
post_failure_case 'post-Compose network identity drift is contained' RECREATED_CONTAINER_CONTRACT_MISMATCH NETWORK_CHANGE_AFTER_COMPOSE yes 1
post_failure_case 'network drift during health polling is contained immediately' RECREATED_CONTAINER_CONTRACT_MISMATCH NEW_NETWORK_DRIFT_AFTER_INSPECT 2 1

reset_case
set_state RM_FAIL yes
set +e; run_wrapper; status=$?; set -e
((status != 0)) || fail 'failed docker rm unexpectedly succeeded'
/usr/bin/grep -Fxq 'STOP=FAILED_CONTAINER_REMOVAL_FAILED' "$err" || fail 'failed docker rm stopped for the wrong reason'
[[ -d "$root_fixture/eventsales-prod/.v3-postgres-recovery-consumed" ]] || fail 'failed docker rm did not retain consumed marker'
[[ "$(call_count 'rm ')" -eq 1 && "$(call_count 'compose ')" -eq 0 && "$(call_count 'stop ')" -eq 0 ]] || fail 'failed docker rm continued or retried'
/usr/bin/grep -Fxq 'RECOVERY_STATE=RECOVERY_FAILED_CONTAINED' "$err" || fail 'failed docker rm did not report contained state'
pass 'failed docker rm consumes authority and stops before Compose'

post_failure_case 'containment stop failure is uncontained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_IMAGE wrong 1 1 STOP_FAIL yes RECOVERY_FAILED_UNCONTAINED
post_failure_case 'still-running after containment is uncontained' RECREATED_CONTAINER_CONTRACT_MISMATCH PG_IMAGE wrong 1 1 STOP_STILL_RUNNING yes RECOVERY_FAILED_UNCONTAINED

for file in "$old_provision" "$old_start" "$old_bootstrap" "$old_sudoers" "$audit_sudoers"; do
  [[ -f "$file" ]] || fail "historical authority missing: $file"
done
[[ "$(sha256sum "$old_provision" | awk '{print $1}')" == 4ede4ad5ae0696ee605bd890e3ced9a18d8d5ac4c7a11992325823de7e5cdad3 ]] || fail 'historical provision wrapper drift'
[[ "$(sha256sum "$old_start" | awk '{print $1}')" == b054b6e97da5e8455615534273168fe4322ce7f6800a5b6486892027df33b567 ]] || fail 'historical start wrapper drift'
[[ "$(sha256sum "$old_bootstrap" | awk '{print $1}')" == b763431776faf81a8cc84b61c494b3ed22bb8bf732962306973878e83fae79ab ]] || fail 'historical bootstrap wrapper drift'
[[ "$(sha256sum "$old_sudoers" | awk '{print $1}')" == 8575c6c1e85d111bb78b360b8e03f2c9f6e6a1dfccc5fbc0273003a354bc51d3 ]] || fail 'historical V3 sudoers drift'
[[ "$(sha256sum "$audit_sudoers" | awk '{print $1}')" == 52c7e97b51338bcaa34ebe74ed5731055bf3dfa36000af3fa826315ce5a2d974 ]] || fail 'audit sudoers drift'
pass 'historical V3 and audit authority hashes remain exact'

printf 'RECOVERY_TEST_COUNT=%s\n' "$passes"
printf 'RECOVERY_TESTS_PASSED=%s\n' "$passes"
