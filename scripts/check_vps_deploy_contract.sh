#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  local check="${1:-SAFE_ID}"
  if [[ ! "$check" =~ ^[A-Z0-9_]+$ ]]; then
    check=SAFE_ID
  fi
  printf 'STOP=VPS_DEPLOY_CONTRACT_FAILED check=%s\n' "$check" >&2
  exit 1
}

if (($# != 0)); then
  fail ARGUMENTS
fi

for tool in docker jq timeout grep awk cmp mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail TOOLING
done

DATA_COMPOSE="$ROOT/deploy/vps/data-plane/compose.yaml"
NETWORK_SCRIPT="$ROOT/deploy/vps/data-plane/scripts/provision-networks.sh"
PGBOUNCER_TEMPLATE="$ROOT/deploy/vps/data-plane/templates/pgbouncer.ini.template"
REDIS_ACL_TEMPLATE="$ROOT/deploy/vps/data-plane/templates/redis-users.acl.template"
APP_COMPOSE="$ROOT/deploy/vps/app/compose.yaml"
INGRESS_COMPOSE="$ROOT/deploy/vps/app/compose.ingress.yaml"
RUNTIME_CONFIG="$ROOT/config/runtime.exs"

for source_file in \
  "$DATA_COMPOSE" \
  "$NETWORK_SCRIPT" \
  "$PGBOUNCER_TEMPLATE" \
  "$REDIS_ACL_TEMPLATE" \
  "$APP_COMPOSE" \
  "$INGRESS_COMPOSE" \
  "$RUNTIME_CONFIG"; do
  [[ -f "$source_file" && -r "$source_file" ]] || fail SOURCE_FILE_MISSING
done

TMP_DIR="$(mktemp -d /tmp/vps-deploy-contract.XXXXXX 2>/dev/null)" || fail TEMP_DIR
trap 'rm -rf -- "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/secrets" "$TMP_DIR/home" "$TMP_DIR/docker-config" 2>/dev/null || fail TEMP_DIR
: 2>/dev/null > "$TMP_DIR/runtime.env" || fail TEMP_DIR
for secret_name in \
  postgres_bootstrap_password \
  pgbouncer.ini \
  pgbouncer_users.txt \
  redis-users.acl; do
  : 2>/dev/null > "$TMP_DIR/secrets/$secret_name" || fail TEMP_DIR
done

APP_IMAGE='ghcr.io/jcschoeman96/eventsales@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
NODE_IP='172.31.255.10'

line_is_present() {
  local source_file=$1
  local expected_line=$2
  grep -Fqx -- "$expected_line" "$source_file" 2>/dev/null
}

secret_source_gate() {
  local expected
  local source_file
  local line

  for expected in \
    '    file: ${EVENTSALES_SECRET_DIR:?EVENTSALES_SECRET_DIR_must_be_set}/postgres_bootstrap_password' \
    '    file: ${EVENTSALES_SECRET_DIR:?EVENTSALES_SECRET_DIR_must_be_set}/pgbouncer.ini' \
    '    file: ${EVENTSALES_SECRET_DIR:?EVENTSALES_SECRET_DIR_must_be_set}/pgbouncer_users.txt' \
    '    file: ${EVENTSALES_SECRET_DIR:?EVENTSALES_SECRET_DIR_must_be_set}/redis-users.acl'; do
    line_is_present "$DATA_COMPOSE" "$expected" || fail COMMITTED_SECRET_LITERAL
  done

  line_is_present "$APP_COMPOSE" \
    '      - "${EVENTSALES_DEPLOY_ENV_FILE:?EVENTSALES_DEPLOY_ENV_FILE_must_be_set}"' \
    || fail COMMITTED_SECRET_LITERAL
  if ! awk '
    $0 == "    env_file:" { sections++; in_env_file = 1; next }
    in_env_file && $0 ~ /^    [^ ]/ { in_env_file = 0 }
    in_env_file && $0 ~ /^      - / { entries++ }
    END { if (sections != 1 || entries != 1) exit 1 }
  ' "$APP_COMPOSE" 2>/dev/null; then
    fail APP_RUNTIME_ENVIRONMENT
  fi

  line_is_present "$APP_COMPOSE" \
    '    image: "${EVENTSALES_IMAGE_REF:?EVENTSALES_IMAGE_REF_must_be_set}"' \
    || fail APP_IMAGE_REQUIRED
  line_is_present "$APP_COMPOSE" \
    '      EVENTSALES_NODE_IP: "${EVENTSALES_NODE_IP:?EVENTSALES_NODE_IP_must_be_set}"' \
    || fail APP_NODE_IDENTITY
  line_is_present "$APP_COMPOSE" \
    '        ipv4_address: "${EVENTSALES_NODE_IP:?EVENTSALES_NODE_IP_must_be_set}"' \
    || fail APP_NODE_IDENTITY

  line_is_present "$PGBOUNCER_TEMPLATE" \
    'event_sales_prod = host=postgres port=5432 dbname=event_sales_prod user=eventsales_runtime password=__EVENTSALES_RUNTIME_SERVER_PASSWORD__' \
    || fail COMMITTED_SECRET_LITERAL

  for source_file in \
    "$DATA_COMPOSE" \
    "$PGBOUNCER_TEMPLATE" \
    "$REDIS_ACL_TEMPLATE" \
    "$APP_COMPOSE" \
    "$INGRESS_COMPOSE"; do
    if grep -Eiq -- \
      '[[:alpha:]][[:alnum:].+-]*://[^/@[:space:]]+:[^/@[:space:]]+@|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[[:alnum:]]{20,}|AKIA[0-9A-Z]{16}' \
      "$source_file" 2>/dev/null; then
      fail COMMITTED_SECRET_LITERAL
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
      lower_line="${line,,}"
      if [[ "$lower_line" =~ (password|passwd|pgpassword|pgpassfile|token|api[_-]?key|client[_-]?secret|secret|credential|private[_-]?key|secret_key_base|release_cookie)[[:space:]]*[:=][[:space:]]*([^[:space:]]+) ]]; then
        if [[ "$source_file" == "$PGBOUNCER_TEMPLATE" && \
          "$lower_line" == *'password=__eventsales_runtime_server_password__' ]]; then
          continue
        fi
        fail COMMITTED_SECRET_LITERAL
      fi
    done < "$source_file"
  done

  if grep -Eiq -- '(^|[[:space:]])#[[:xdigit:]]{64}([[:space:]]|$)' "$REDIS_ACL_TEMPLATE" 2>/dev/null; then
    fail COMMITTED_SECRET_LITERAL
  fi
  if grep -Eq -- '(^|[[:space:]])>[^[:space:]]+' "$REDIS_ACL_TEMPLATE" 2>/dev/null; then
    fail COMMITTED_SECRET_LITERAL
  fi

  if grep -Fq -- 'prepare: :unnamed' "$RUNTIME_CONFIG" 2>/dev/null; then
    fail PGBOUNCER_PREPARED_STATEMENTS
  fi
}

secret_source_gate

json_must_match() {
  local check=$1
  local json_file=$2
  local query=$3
  shift 3
  if ! jq -e "$@" "$query" "$json_file" >/dev/null 2>&1; then
    fail "$check"
  fi
}

render_data_plane() {
  timeout 20s env -i \
    PATH="$PATH" \
    LC_ALL=C \
    HOME="$TMP_DIR/home" \
    DOCKER_CONFIG="$TMP_DIR/docker-config" \
    TMPDIR="$TMP_DIR" \
    EVENTSALES_SECRET_DIR="$TMP_DIR/secrets" \
    docker compose \
      --env-file /dev/null \
      -f "$DATA_COMPOSE" \
      config --format json
}

render_app_without_image() {
  timeout 20s env -i \
    PATH="$PATH" \
    LC_ALL=C \
    HOME="$TMP_DIR/home" \
    DOCKER_CONFIG="$TMP_DIR/docker-config" \
    TMPDIR="$TMP_DIR" \
    EVENTSALES_DEPLOY_ENV_FILE="$TMP_DIR/runtime.env" \
    EVENTSALES_NODE_IP="$NODE_IP" \
    docker compose \
      --env-file /dev/null \
      -f "$APP_COMPOSE" \
      config --format json
}

render_app() {
  local output=$1
  shift
  local compose_file
  local -a compose_args=()

  for compose_file in "$@"; do
    compose_args+=( -f "$compose_file" )
  done

  timeout 20s env -i \
    PATH="$PATH" \
    LC_ALL=C \
    HOME="$TMP_DIR/home" \
    DOCKER_CONFIG="$TMP_DIR/docker-config" \
    TMPDIR="$TMP_DIR" \
    EVENTSALES_IMAGE_REF="$APP_IMAGE" \
    EVENTSALES_DEPLOY_ENV_FILE="$TMP_DIR/runtime.env" \
    EVENTSALES_NODE_IP="$NODE_IP" \
    docker compose \
      --env-file /dev/null \
      "${compose_args[@]}" \
      config --format json > "$output" 2> "$TMP_DIR/render.err"
}

if ! env -i PATH="$PATH" LC_ALL=C HOME="$TMP_DIR/home" DOCKER_CONFIG="$TMP_DIR/docker-config" \
  timeout 20s docker compose version --short >/dev/null 2>&1; then
  fail DOCKER_COMPOSE_UNAVAILABLE
fi

if render_app_without_image > "$TMP_DIR/app-without-image.json" 2> "$TMP_DIR/app-without-image.err"; then
  fail APP_IMAGE_REQUIRED
else
  render_status=$?
  [[ "$render_status" -ne 124 && "$render_status" -ne 137 ]] || fail APP_IMAGE_REQUIRED
fi

if ! render_data_plane > "$TMP_DIR/data-plane.json" 2> "$TMP_DIR/data-plane.err"; then
  fail DATA_PLANE_RENDER
fi

if ! render_app "$TMP_DIR/app-base.json" "$APP_COMPOSE"; then
  fail APP_BASE_RENDER
fi

if ! render_app "$TMP_DIR/app-ingress.json" "$APP_COMPOSE" "$INGRESS_COMPOSE"; then
  fail APP_INGRESS_RENDER
fi

json_must_match DATA_PLANE_JSON "$TMP_DIR/data-plane.json" 'type == "object" and (.services | type == "object")'
json_must_match APP_BASE_JSON "$TMP_DIR/app-base.json" 'type == "object" and (.services.app | type == "object")'
json_must_match APP_INGRESS_JSON "$TMP_DIR/app-ingress.json" 'type == "object" and (.services.app | type == "object")'

if ! jq -c 'del(.services.app.ports)' "$TMP_DIR/app-base.json" > "$TMP_DIR/app-base-normalized.json" 2>/dev/null || \
  ! jq -c 'del(.services.app.ports)' "$TMP_DIR/app-ingress.json" > "$TMP_DIR/app-ingress-normalized.json" 2>/dev/null; then
  fail APP_NORMALIZATION
fi
cmp -s "$TMP_DIR/app-base-normalized.json" "$TMP_DIR/app-ingress-normalized.json" || fail INGRESS_OVERLAY_DRIFT

json_must_match DATA_PROJECT "$TMP_DIR/data-plane.json" \
  '(.name == "eventsales-prod") and ((.services | keys | sort) == ["pgbouncer", "postgres", "redis"])'
json_must_match DATA_NETWORKS "$TMP_DIR/data-plane.json" \
  '((.networks | keys | sort) == ["eventsales_data"]) and (.networks.eventsales_data.external == true) and (.networks.eventsales_data.name == "eventsales-prod_eventsales_data")'
json_must_match DATA_NO_HOST_PORTS "$TMP_DIR/data-plane.json" \
  'all(.services[]; ((has("ports") | not) and (((.networks | if type == "array" then sort else keys end) == ["eventsales_data"]))))'
json_must_match DATA_VOLUME "$TMP_DIR/data-plane.json" \
  '((.volumes | keys | sort) == ["postgres_data"]) and (.volumes.postgres_data.name == "eventsales-prod_postgres_data") and ((.services.postgres.volumes | length) == 1) and (.services.postgres.volumes[0].type == "volume") and (.services.postgres.volumes[0].source == "postgres_data") and (.services.postgres.volumes[0].target == "/var/lib/postgresql")'

POSTGRES_IMAGE='dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19'
PGBOUNCER_IMAGE='ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:965b0223f1096666471e11595f4f6dc5d32dfacbc688418b8ae2385946c41e3b'
REDIS_IMAGE='dhi.io/redis:8.10.2-debian13@sha256:953ca2c2ab4ff7a93f8abac31339ba4d913ec0914861453ab4faa29d154115a0'

json_must_match POSTGRES_CONTRACT "$TMP_DIR/data-plane.json" \
  '(.services.postgres.image == $image) and (.services.postgres.cpus == 2) and ((.services.postgres.mem_limit == "3221225472") or (.services.postgres.mem_limit == "3g") or (.services.postgres.mem_limit == 3221225472)) and (.services.postgres.expose == ["5432"]) and (.services.postgres.environment.POSTGRES_DB == "postgres") and (.services.postgres.environment.POSTGRES_USER == "postgres") and (.services.postgres.environment.POSTGRES_PASSWORD_FILE == "/run/secrets/postgres_bootstrap_password") and ((.services.postgres.environment | has("POSTGRES_PASSWORD")) | not) and (.services.postgres.command == ["postgres", "-c", "max_connections=100", "-c", "shared_buffers=768MB", "-c", "effective_cache_size=2GB", "-c", "work_mem=8MB", "-c", "maintenance_work_mem=256MB"])' \
  --arg image "$POSTGRES_IMAGE"

json_must_match PGBOUNCER_CONTAINER "$TMP_DIR/data-plane.json" \
  '(.services.pgbouncer.image == $image) and (.services.pgbouncer.user == "65532:65532") and (.services.pgbouncer.read_only == true) and (.services.pgbouncer.cap_drop == ["ALL"]) and ((.services.pgbouncer.cap_add // []) == []) and ((.services.pgbouncer.privileged // false) == false) and (.services.pgbouncer.security_opt == ["no-new-privileges:true"]) and (.services.pgbouncer.cpus == 0.5) and ((.services.pgbouncer.mem_limit == "134217728") or (.services.pgbouncer.mem_limit == "128m") or (.services.pgbouncer.mem_limit == 134217728)) and (.services.pgbouncer.expose == ["6432"])' \
  --arg image "$PGBOUNCER_IMAGE"

json_must_match REDIS_CONTAINER "$TMP_DIR/data-plane.json" \
  '(.services.redis.image == $image) and (.services.redis.user == "65532:65532") and (.services.redis.read_only == true) and (.services.redis.cap_drop == ["ALL"]) and ((.services.redis.cap_add // []) == []) and ((.services.redis.privileged // false) == false) and (.services.redis.security_opt == ["no-new-privileges:true"]) and (.services.redis.cpus == 0.5) and ((.services.redis.mem_limit == "536870912") or (.services.redis.mem_limit == "512m") or (.services.redis.mem_limit == 536870912)) and (.services.redis.expose == ["6379"]) and (.services.redis.command == ["redis-server", "/etc/redis/redis.conf", "--bind", "0.0.0.0", "--protected-mode", "no", "--aclfile", "/run/secrets/redis-users.acl", "--maxmemory", "384mb", "--maxmemory-policy", "noeviction", "--save", "", "--appendonly", "no", "--dir", "/tmp", "--logfile", ""])' \
  --arg image "$REDIS_IMAGE"

line_is_present "$NETWORK_SCRIPT" 'DATA_NETWORK=eventsales-prod_eventsales_data' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'EDGE_NETWORK=eventsales-prod_eventsales_edge' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'check_network "$DATA_NETWORK" true' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'check_network "$EDGE_NETWORK" false' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'provision_network "$DATA_NETWORK" true "$DATA_NETWORK_STATE"' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'provision_network "$EDGE_NETWORK" false "$EDGE_NETWORK_STATE"' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" '    if [[ "$expected_internal" == true ]]; then' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" '      docker network create --driver bridge --internal "$name" >/dev/null || {' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" '      docker network create --driver bridge "$name" >/dev/null || {' || fail DATA_NETWORK_PROVISIONER

ini_setting_is() {
  local wanted_key=$1
  local expected_value=$2
  awk -v wanted_key="$wanted_key" -v expected_value="$expected_value" '
    function trim(value) {
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
      return value
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^[;#]/) next
      if (line ~ /^\[/) {
        section = line
        next
      }
      if (section != "[pgbouncer]" || index(line, "=") == 0) next
      separator = index(line, "=")
      key = trim(substr(line, 1, separator - 1))
      value = trim(substr(line, separator + 1))
      if (key == wanted_key) {
        count++
        if (value != expected_value) bad = 1
      }
    }
    END { if (count != 1 || bad) exit 1 }
  ' "$PGBOUNCER_TEMPLATE" 2>/dev/null
}

for pair in \
  'listen_port 6432' \
  'auth_type scram-sha-256' \
  'pool_mode transaction' \
  'max_client_conn 64' \
  'default_pool_size 12' \
  'reserve_pool_size 4' \
  'max_db_connections 16' \
  'max_user_connections 16' \
  'max_prepared_statements 200'; do
  setting_key=${pair%% *}
  setting_value=${pair#* }
  ini_setting_is "$setting_key" "$setting_value" || fail PGBOUNCER_SETTINGS
done

check_acl_tokens() {
  local expected_name=$1
  shift
  local -a expected_tokens=( "$@" )
  local token_count=${#acl_tokens[@]}
  local index

  ((token_count == ${#expected_tokens[@]})) || return 1
  for ((index = 0; index < token_count; index++)); do
    [[ "${acl_tokens[index]}" == "${expected_tokens[index]}" ]] || return 1
  done
  [[ "${acl_tokens[1]}" == "$expected_name" ]]
}

check_redis_acl() {
  local line
  local default_count=0
  local runtime_count=0
  local stats_count=0
  local -a acl_tokens=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    read -r -a acl_tokens <<< "$line"
    case "${acl_tokens[1]-}" in
      default)
        default_count=$((default_count + 1))
        check_acl_tokens default user default on nopass resetkeys resetchannels -@all +ping || return 1
        ;;
      eventsales_runtime)
        runtime_count=$((runtime_count + 1))
        check_acl_tokens eventsales_runtime \
          user eventsales_runtime on \
          '#__EVENTSALES_REDIS_RUNTIME_PASSWORD_SHA256_64HEX__' \
          resetkeys resetchannels -@all '~eventsales:prod:*' \
          +ping +get +set +del +exists +expire +pexpire +ttl +pttl \
          +multi +exec +discard +zadd +zrem +zcard +zremrangebyscore +scan || return 1
        ;;
      eventsales_stats)
        stats_count=$((stats_count + 1))
        check_acl_tokens eventsales_stats \
          user eventsales_stats on \
          '#__EVENTSALES_REDIS_STATS_PASSWORD_SHA256_64HEX__' \
          resetkeys resetchannels -@all +ping +info +config\|get || return 1
        ;;
      *)
        return 1
        ;;
    esac
  done < "$REDIS_ACL_TEMPLATE"

  ((default_count == 1 && runtime_count == 1 && stats_count == 1))
}

check_redis_acl || fail REDIS_ACL

json_must_match APP_BASE "$TMP_DIR/app-base.json" \
  '(.name == "eventsales-app") and ((.services | keys) == ["app"]) and (.services.app.image == $image) and ((.services.app | has("build")) | not) and ((.services.app | has("ports")) | not) and (.services.app.user == "eventsales") and (.services.app.init == true) and (.services.app.restart == "unless-stopped") and (.services.app.read_only == true) and (.services.app.cap_drop == ["ALL"]) and ((.services.app.cap_add // []) == []) and ((.services.app.privileged // false) == false) and (.services.app.security_opt == ["no-new-privileges:true"]) and (.services.app.cpus == 4) and ((.services.app.mem_limit == "2147483648") or (.services.app.mem_limit == "2g") or (.services.app.mem_limit == 2147483648)) and (.services.app.pids_limit == 512) and (.services.app.tmpfs == ["/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777"]) and (.services.app.expose == ["4000"]) and (.services.app.healthcheck.test == ["CMD", "bin/event_sales", "pid"]) and (.services.app.environment == {"PHX_SERVER":"true", "PORT":"4000", "POOL_SIZE":"20", "DNS_CLUSTER_QUERY":"eventsales-app", "EVENTSALES_NODE_IP":$node_ip, "WEBHOOK_REDIS_BUFFER_ENABLED":"false", "WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED":"false"}) and ((.services.app | has("volumes")) | not) and ((.networks | keys | sort) == ["eventsales_data", "eventsales_edge"]) and (.networks.eventsales_data.external == true) and (.networks.eventsales_data.name == "eventsales-prod_eventsales_data") and (.networks.eventsales_edge.external == true) and (.networks.eventsales_edge.name == "eventsales-prod_eventsales_edge") and ((.services.app.networks.eventsales_data.aliases // []) == ["eventsales-app"]) and (.services.app.networks.eventsales_data.ipv4_address == $node_ip) and (((.services.app.networks.eventsales_edge // {}) | keys | length) == 0)' \
  --arg image "$APP_IMAGE" \
  --arg node_ip "$NODE_IP"

json_must_match APP_INGRESS "$TMP_DIR/app-ingress.json" \
  '(.services.app.ports | length == 1) and (.services.app.ports[0].host_ip == "127.0.0.1") and ((.services.app.ports[0].target == 4000) or (.services.app.ports[0].target == "4000")) and ((.services.app.ports[0].published == "4100") or (.services.app.ports[0].published == 4100)) and (.services.app.ports[0].protocol == "tcp") and ((.services.app.ports[0].mode // "ingress") == "ingress")'

printf 'VPS_DEPLOY_CONTRACT=PASS\n'
