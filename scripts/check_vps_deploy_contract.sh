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

for tool in docker python3 timeout grep awk cmp mktemp sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail TOOLING
done

DATA_COMPOSE="$ROOT/deploy/vps/data-plane/compose.yaml"
NETWORK_SCRIPT="$ROOT/deploy/vps/data-plane/scripts/provision-networks.sh"
PGBOUNCER_TEMPLATE="$ROOT/deploy/vps/data-plane/templates/pgbouncer.ini.template"
REDIS_ACL_TEMPLATE="$ROOT/deploy/vps/data-plane/templates/redis-users.acl.template"
APP_COMPOSE="$ROOT/deploy/vps/app/compose.yaml"
INGRESS_COMPOSE="$ROOT/deploy/vps/app/compose.ingress.yaml"
RUNTIME_CONFIG="$ROOT/config/runtime.exs"
SECRET_GENERATOR="$ROOT/deploy/vps/data-plane/scripts/generate-secrets.sh"
RUNTIME_RENDERER="$ROOT/deploy/vps/data-plane/scripts/render-runtime-config.sh"
POSTGRES_BOOTSTRAP="$ROOT/deploy/vps/data-plane/scripts/bootstrap-postgres.sh"
RECOVERY_WRAPPER="$ROOT/deploy/vps/operator/agent-eventsales-v3-recover-postgres"
RECOVERY_SUDOERS="$ROOT/deploy/vps/operator/agent-eventsales-v3-recover-postgres.sudoers"
BOOTSTRAP_V2_WRAPPER="$ROOT/deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres-v2"
BOOTSTRAP_V2_SUDOERS="$ROOT/deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres-v2.sudoers"
V4_WRAPPER="$ROOT/deploy/vps/operator/agent-eventsales-v4-start-data-plane"
V4_SUDOERS="$ROOT/deploy/vps/operator/agent-eventsales-v4-start-data-plane.sudoers"
DEPLOY_PROBE_SCRIPTS=(
  "$ROOT/deploy/vps/data-plane/scripts/probe-postgres.sh"
  "$ROOT/deploy/vps/data-plane/scripts/probe-pgbouncer.sh"
  "$ROOT/deploy/vps/data-plane/scripts/probe-redis.sh"
  "$ROOT/deploy/vps/app/scripts/probe-private.sh"
  "$ROOT/deploy/vps/app/scripts/probe-loopback.sh"
)
# Pin the accepted provisioner control flow so a bypass cannot hide beside expected lines.
NETWORK_SCRIPT_SHA256='dc22844432d1591bd31abfb7b62595afa373ac13a113dd2a7553633e02813348'

for source_file in \
  "$DATA_COMPOSE" \
  "$NETWORK_SCRIPT" \
  "$PGBOUNCER_TEMPLATE" \
  "$REDIS_ACL_TEMPLATE" \
  "$APP_COMPOSE" \
  "$INGRESS_COMPOSE" \
  "$RUNTIME_CONFIG" \
  "$SECRET_GENERATOR" \
  "$RUNTIME_RENDERER" \
  "$POSTGRES_BOOTSTRAP" \
  "$RECOVERY_WRAPPER" \
  "$RECOVERY_SUDOERS" \
  "$BOOTSTRAP_V2_WRAPPER" \
  "$BOOTSTRAP_V2_SUDOERS" \
  "$V4_WRAPPER" \
  "$V4_SUDOERS" \
  "${DEPLOY_PROBE_SCRIPTS[@]}"; do
  [[ -f "$source_file" && -r "$source_file" ]] || fail SOURCE_FILE_MISSING
done

[[ -x "$RECOVERY_WRAPPER" && ! -L "$RECOVERY_WRAPPER" ]] || fail RECOVERY_WRAPPER_TYPE
bash -n "$RECOVERY_WRAPPER" || fail RECOVERY_WRAPPER_SYNTAX
expected_recovery_rule='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-recover-postgres ""'
[[ "$(cat -- "$RECOVERY_SUDOERS")" == "$expected_recovery_rule" ]] || fail RECOVERY_SUDOERS_RULE
[[ $(wc -l <"$RECOVERY_SUDOERS") -eq 1 ]] || fail RECOVERY_SUDOERS_SCOPE
grep -Fqx 'readonly COMPOSE_SHA256='\''3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218'\''' "$RECOVERY_WRAPPER" || fail RECOVERY_COMPOSE_PIN
grep -Fqx 'readonly OVERRIDE_SHA256='\''cc4bc2cee5847d9d24984ccc5521ef81868aeb77456e66b94df62c50685f2e14'\''' "$RECOVERY_WRAPPER" || fail RECOVERY_VOLUME_OVERRIDE_PIN
grep -Fq 'up -d --no-deps postgres' "$RECOVERY_WRAPPER" || fail RECOVERY_SERVICE_SCOPE
grep -Fq 'docker_fixed rm "$FAILED_POSTGRES_CONTAINER_ID"' "$RECOVERY_WRAPPER" || fail RECOVERY_REMOVE_BY_ID
grep -Fq 'docker_fixed stop --time 10 "$NEW_POSTGRES_ID"' "$RECOVERY_WRAPPER" || fail RECOVERY_CONTAINMENT_BY_ID
if grep -Eiq 'docker[[:space:]]+(volume[[:space:]]+rm|system[[:space:]]+prune)|compose[[:space:]]+down[[:space:]]+-v' "$RECOVERY_WRAPPER"; then
  fail RECOVERY_STORAGE_MUTATION
fi

[[ -x "$BOOTSTRAP_V2_WRAPPER" && ! -L "$BOOTSTRAP_V2_WRAPPER" ]] || fail BOOTSTRAP_V2_WRAPPER_TYPE
bash -n "$BOOTSTRAP_V2_WRAPPER" || fail BOOTSTRAP_V2_WRAPPER_SYNTAX
expected_bootstrap_v2_rule='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-bootstrap-postgres-v2 ""'
[[ "$(cat -- "$BOOTSTRAP_V2_SUDOERS")" == "$expected_bootstrap_v2_rule" ]] || fail BOOTSTRAP_V2_SUDOERS_RULE
[[ $(wc -l <"$BOOTSTRAP_V2_SUDOERS") -eq 1 ]] || fail BOOTSTRAP_V2_SUDOERS_SCOPE
grep -Fqx 'readonly SOURCE_SHA='\''c9ce0f9239123a6e58f66fde0b5a1e60238bb107'\''' "$BOOTSTRAP_V2_WRAPPER" || fail BOOTSTRAP_V2_STAGE_PIN
grep -Fqx 'readonly EXPECTED_COMPOSE_SHA256='\''3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218'\''' "$BOOTSTRAP_V2_WRAPPER" || fail BOOTSTRAP_V2_COMPOSE_PIN
grep -Fqx 'readonly EXPECTED_BOOTSTRAP_SHA256='\''afa7c663abd06ec109bbb9172f2d5391fa856e3dfbff1a1f90da29a46265fa7f'\''' "$BOOTSTRAP_V2_WRAPPER" || fail BOOTSTRAP_V2_CHILD_PIN
grep -Fqx 'readonly EXPECTED_PROBE_SHA256='\''3019e4560946957e27f3fca033c754dda1cf9a66adebd61a46208d87b24e77ce'\''' "$BOOTSTRAP_V2_WRAPPER" || fail BOOTSTRAP_V2_PROBE_PIN
/usr/sbin/visudo -cf "$BOOTSTRAP_V2_SUDOERS" >/dev/null || fail BOOTSTRAP_V2_SUDOERS_SYNTAX

[[ -x "$V4_WRAPPER" && ! -L "$V4_WRAPPER" ]] || fail V4_WRAPPER_TYPE
bash -n "$V4_WRAPPER" || fail V4_WRAPPER_SYNTAX
expected_v4_rule='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v4-start-data-plane ""'
[[ "$(cat -- "$V4_SUDOERS")" == "$expected_v4_rule" ]] || fail V4_SUDOERS_RULE
[[ $(wc -l <"$V4_SUDOERS") -eq 1 ]] || fail V4_SUDOERS_SCOPE
grep -Fqx 'readonly SOURCE_SHA='\''c9ce0f9239123a6e58f66fde0b5a1e60238bb107'\''' "$V4_WRAPPER" || fail V4_STAGE_PIN
grep -Fqx 'readonly EXPECTED_COMPOSE_SHA256='\''3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218'\''' "$V4_WRAPPER" || fail V4_COMPOSE_PIN
grep -Fqx 'readonly PGBOUNCER_IMAGE='\''ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:965b0223f1096666471e11595f4f6dc5d32dfacbc688418b8ae2385946c41e3b'\''' "$V4_WRAPPER" || fail V4_PGBOUNCER_IMAGE_PIN
grep -Fqx 'readonly REDIS_IMAGE='\''dhi.io/redis:8.10.2-debian13@sha256:953ca2c2ab4ff7a93f8abac31339ba4d913ec0914861453ab4faa29d154115a0'\''' "$V4_WRAPPER" || fail V4_REDIS_IMAGE_PIN
grep -Fq 'up -d --no-deps pgbouncer redis' "$V4_WRAPPER" || fail V4_SERVICE_SCOPE
if grep -Eiq 'docker[[:space:]]+(stop|restart|rm|kill|pause|unpause|volume[[:space:]]+(rm|create|prune)|network[[:space:]]+(create|rm|connect|disconnect)|system[[:space:]]+prune)|compose[[:space:]]+down' "$V4_WRAPPER"; then
  fail V4_FORBIDDEN_MUTATION
fi
/usr/sbin/visudo -cf "$V4_SUDOERS" >/dev/null || fail V4_SUDOERS_SYNTAX

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

  if ! python3 - "$NETWORK_SCRIPT" "$RUNTIME_CONFIG" "$SECRET_GENERATOR" "$RUNTIME_RENDERER" "$POSTGRES_BOOTSTRAP" "${DEPLOY_PROBE_SCRIPTS[@]}" <<'PY'
import re
import sys

url_credentials = re.compile(r"[A-Za-z][A-Za-z0-9.+-]*://[^/@\s]+:[^/@\s]+@", re.I)
private_key = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", re.I)
token = re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}")
pgpass_field = r"(?:\\.|[^:'\"$\s])+"
pgpass_entry = rf"{pgpass_field}:(?:\*|\d{{1,5}}):{pgpass_field}:{pgpass_field}:{pgpass_field}"
pgpass_literal = re.compile(rf"(?:'{pgpass_entry}'|\"{pgpass_entry}\")")
pgpass_line_literal = re.compile(rf"(?m)^[ \t]*{pgpass_entry}[ \t]*$")
quoted_literal = re.compile(
    r"(?<![A-Za-z0-9])(?:POSTGRES_PASSWORD|PGPASSWORD|DIRECT_DATABASE_URL|"
    r"DATABASE_URL|REDIS_URL|SECRET_KEY_BASE|RELEASE_COOKIE|EVENTSALES_[A-Z_]*(?:PASSWORD|SECRET|TOKEN)|"
    r"[A-Za-z0-9_]*(?:PASSWORD|PASSWD|TOKEN|API[_-]?KEY|CLIENT[_-]?SECRET|SECRET_KEY_BASE|"
    r"RELEASE_COOKIE|DATABASE_URL|REDIS_URL|CREDENTIAL|PRIVATE[_-]?KEY))"
    r"\s*[:=]\s*(?:\"[^\"]+\"|'[^']+')",
    re.I,
)
unquoted_environment_value = re.compile(
    r"(?<![A-Za-z0-9])(?:POSTGRES_PASSWORD|PGPASSWORD|DIRECT_DATABASE_URL|DATABASE_URL|"
    r"REDIS_URL|SECRET_KEY_BASE|RELEASE_COOKIE|EVENTSALES_[A-Z_]*(?:PASSWORD|SECRET|TOKEN))"
    r"\s*=\s*[^$\s\"']+",
)
environment_literal = re.compile(
    r"System\.(?:put_env|put_env!)\s*\(\s*[\"'](?:POSTGRES_PASSWORD|PGPASSWORD|"
    r"DIRECT_DATABASE_URL|DATABASE_URL|REDIS_URL|SECRET_KEY_BASE|RELEASE_COOKIE|"
    r"EVENTSALES_[A-Z_]*(?:PASSWORD|SECRET|TOKEN)|[A-Z0-9_]*(?:PASSWORD|PASSWD|TOKEN|SECRET_KEY_BASE))"
    r"[\"']\s*,\s*[\"'][^\"']+[\"']",
    re.I,
)

for path in sys.argv[1:]:
    source = open(path, encoding="utf-8").read()
    source = source.replace("ecto://USER:PASS@HOST/DATABASE", "")
    if any(pattern.search(source) for pattern in (
        url_credentials, private_key, token, pgpass_literal, pgpass_line_literal, quoted_literal,
        unquoted_environment_value, environment_literal
    )):
        sys.exit(1)
PY
  then
    fail COMMITTED_SECRET_LITERAL
  fi

  if grep -Eiq -- '(^|[[:space:]])#[[:xdigit:]]{64}([[:space:]]|$)' "$REDIS_ACL_TEMPLATE" 2>/dev/null; then
    fail COMMITTED_SECRET_LITERAL
  fi
  if grep -Eq -- '(^|[[:space:]])>[^[:space:]]+' "$REDIS_ACL_TEMPLATE" 2>/dev/null; then
    fail COMMITTED_SECRET_LITERAL
  fi

  if python3 - "$RUNTIME_CONFIG" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
sys.exit(0 if re.search(r"\bprepare\s*:\s*:unnamed\b", source) else 1)
PY
  then
    fail PGBOUNCER_PREPARED_STATEMENTS
  fi
}

secret_source_gate

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

cat > "$TMP_DIR/contract_validator.py" <<'PY'
import json
import sys

APP_IMAGE = "ghcr.io/jcschoeman96/eventsales@sha256:" + "a" * 64
NODE_IP = "172.31.255.10"
POSTGRES_IMAGE = "dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19"
PGBOUNCER_IMAGE = "ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:965b0223f1096666471e11595f4f6dc5d32dfacbc688418b8ae2385946c41e3b"
REDIS_IMAGE = "dhi.io/redis:8.10.2-debian13@sha256:953ca2c2ab4ff7a93f8abac31339ba4d913ec0914861453ab4faa29d154115a0"


def read(path):
    with open(path, encoding="utf-8") as source:
        return json.load(source)


def require(condition):
    if not condition:
        raise ValueError


def is_memory(value, accepted):
    return value in accepted


def require_healthcheck(service, test, start_period):
    require(service.get("healthcheck") == {
        "test": test,
        "interval": "10s",
        "timeout": "3s",
        "retries": 5,
        "start_period": start_period,
    })


def network_names(value):
    if isinstance(value, list):
        return sorted(value)
    if isinstance(value, dict):
        return sorted(value)
    return None


def check(mode, paths):
    if mode == "DATA_PLANE_JSON":
        data = read(paths[0])
        require(isinstance(data, dict) and isinstance(data.get("services"), dict))
    elif mode == "APP_BASE_JSON":
        require(isinstance(read(paths[0]).get("services", {}).get("app"), dict))
    elif mode == "APP_INGRESS_JSON":
        require(isinstance(read(paths[0]).get("services", {}).get("app"), dict))
    elif mode == "APP_OVERLAY_EQUAL":
        base, ingress = (read(path) for path in paths)
        base["services"]["app"].pop("ports", None)
        ingress["services"]["app"].pop("ports", None)
        require(base == ingress)
    elif mode == "DATA_PROJECT":
        data = read(paths[0])
        require(data.get("name") == "eventsales-prod")
        require(sorted(data.get("services", {})) == ["pgbouncer", "postgres", "redis"])
    elif mode == "DATA_NETWORKS":
        data = read(paths[0])
        networks = data.get("networks", {})
        require(sorted(networks) == ["eventsales_data"])
        require(networks["eventsales_data"].get("external") is True)
        require(networks["eventsales_data"].get("name") == "eventsales-prod_eventsales_data")
    elif mode == "DATA_NO_HOST_PORTS":
        data = read(paths[0])
        for service in data["services"].values():
            require("ports" not in service)
            require(network_names(service.get("networks")) == ["eventsales_data"])
    elif mode == "DATA_VOLUME":
        data = read(paths[0])
        postgres = data["services"]["postgres"]
        volumes = data.get("volumes", {})
        mounts = postgres.get("volumes", [])
        require(sorted(volumes) == ["postgres_data"])
        require(volumes["postgres_data"].get("name") == "eventsales-prod_postgres_data")
        require(len(mounts) == 1)
        require(mounts[0].get("type") == "volume")
        require(mounts[0].get("source") == "postgres_data")
        require(mounts[0].get("target") == "/var/lib/postgresql")
        require(data["services"]["pgbouncer"].get("volumes", []) == [])
        require(data["services"]["redis"].get("volumes", []) == [])
    elif mode == "DATA_SECRET_MOUNTS":
        data = read(paths[0])
        secret_dir = paths[1]
        expected_secrets = {
            "postgres_bootstrap_password": "postgres_bootstrap_password",
            "pgbouncer_ini": "pgbouncer.ini",
            "pgbouncer_users": "pgbouncer_users.txt",
            "redis_acl": "redis-users.acl",
        }
        secrets = data.get("secrets", {})
        require(sorted(secrets) == sorted(expected_secrets))
        for name, filename in expected_secrets.items():
            secret = secrets[name]
            require(secret.get("name") == f"eventsales-prod_{name}")
            require(secret.get("file") == f"{secret_dir}/{filename}")

        expected_mounts = {
            "postgres": [("postgres_bootstrap_password", "postgres_bootstrap_password")],
            "pgbouncer": [
                ("pgbouncer_ini", "/etc/pgbouncer/pgbouncer.ini"),
                ("pgbouncer_users", "/run/secrets/pgbouncer_users.txt"),
            ],
            "redis": [("redis_acl", "/run/secrets/redis-users.acl")],
        }
        for service_name, expected in expected_mounts.items():
            mounts = data["services"][service_name].get("secrets", [])
            actual = [(mount.get("source"), mount.get("target")) for mount in mounts]
            require(actual == expected)
    elif mode == "POSTGRES_CONTRACT":
        postgres = read(paths[0])["services"]["postgres"]
        environment = postgres.get("environment", {})
        require(set(environment) == {
            "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD_FILE",
        })
        require(postgres.get("image") == POSTGRES_IMAGE)
        require(postgres.get("cpus") == 2)
        require(is_memory(postgres.get("mem_limit"), {"3221225472", "3g", 3221225472}))
        require(postgres.get("expose") == ["5432"])
        require(environment.get("POSTGRES_DB") == "postgres")
        require(environment.get("POSTGRES_USER") == "postgres")
        require(environment.get("POSTGRES_PASSWORD_FILE") == "/run/secrets/postgres_bootstrap_password")
        require("POSTGRES_PASSWORD" not in environment)
        require(postgres.get("entrypoint") is None)
        # The DHI PostgreSQL entrypoint invokes postgres; Compose supplies arguments only.
        require(postgres.get("command") == [
            "-c", "max_connections=100", "-c", "shared_buffers=768MB",
            "-c", "effective_cache_size=2GB", "-c", "work_mem=8MB",
            "-c", "maintenance_work_mem=256MB",
        ])
        require_healthcheck(postgres, ["CMD", "pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "postgres"], "30s")
    elif mode == "PGBOUNCER_CONTAINER":
        service = read(paths[0])["services"]["pgbouncer"]
        require(service.get("image") == PGBOUNCER_IMAGE)
        require(service.get("command") is None and service.get("entrypoint") is None)
        require(service.get("user") == "65532:65532")
        require(service.get("read_only") is True)
        require(service.get("cap_drop") == ["ALL"])
        require(service.get("cap_add", []) == [])
        require(service.get("privileged", False) is False)
        require(service.get("security_opt") == ["no-new-privileges:true"])
        require(service.get("cpus") == 0.5)
        require(is_memory(service.get("mem_limit"), {"134217728", "128m", 134217728}))
        require(service.get("expose") == ["6432"])
        require_healthcheck(service, ["CMD", "/usr/local/bin/eventsales-pgbouncer-healthcheck", "127.0.0.1", "6432", "eventsales_runtime"], "10s")
    elif mode == "REDIS_CONTAINER":
        service = read(paths[0])["services"]["redis"]
        require(service.get("image") == REDIS_IMAGE)
        require(service.get("entrypoint") is None)
        require(service.get("user") == "65532:65532")
        require(service.get("read_only") is True)
        require(service.get("cap_drop") == ["ALL"])
        require(service.get("cap_add", []) == [])
        require(service.get("privileged", False) is False)
        require(service.get("security_opt") == ["no-new-privileges:true"])
        require(service.get("cpus") == 0.5)
        require(is_memory(service.get("mem_limit"), {"536870912", "512m", 536870912}))
        require(service.get("expose") == ["6379"])
        require(service.get("command") == [
            "redis-server", "/etc/redis/redis.conf", "--bind", "0.0.0.0",
            "--protected-mode", "no", "--aclfile", "/run/secrets/redis-users.acl",
            "--maxmemory", "384mb", "--maxmemory-policy", "noeviction", "--save", "",
            "--appendonly", "no", "--dir", "/tmp", "--logfile", "",
        ])
        require_healthcheck(service, ["CMD", "redis-cli", "-h", "127.0.0.1", "ping"], "10s")
    elif mode == "PGBOUNCER_SETTINGS":
        expected = {
            "listen_addr": "0.0.0.0",
            "listen_port": "6432",
            "unix_socket_dir": "/tmp",
            "pidfile": "/tmp/pgbouncer.pid",
            "auth_type": "scram-sha-256",
            "auth_file": "/run/secrets/pgbouncer_users.txt",
            "pool_mode": "transaction",
            "max_client_conn": "64",
            "default_pool_size": "12",
            "reserve_pool_size": "4",
            "max_db_connections": "16",
            "max_user_connections": "16",
            "max_prepared_statements": "200",
        }
        section = None
        sections = []
        settings = {}
        database_mappings = []
        with open(paths[0], encoding="utf-8") as source:
            for raw_line in source:
                line = raw_line.strip()
                if not line or line.startswith((";", "#")):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    section = line
                    sections.append(section)
                    continue
                require(section is not None and "=" in line)
                key, value = (part.strip() for part in line.split("=", 1))
                require(key and value)
                if section == "[databases]":
                    database_mappings.append((key, value))
                elif section == "[pgbouncer]":
                    require(key not in settings)
                    settings[key] = value
                else:
                    require(False)
        require(sections == ["[databases]", "[pgbouncer]"])
        require(database_mappings == [(
            "event_sales_prod",
            "host=postgres port=5432 dbname=event_sales_prod user=eventsales_runtime "
            "password=__EVENTSALES_RUNTIME_SERVER_PASSWORD__",
        )])
        require(settings == expected)
    elif mode == "APP_BASE":
        data = read(paths[0])
        app = data["services"]["app"]
        environment = {
            "PHX_SERVER": "true",
            "PORT": "4000",
            "POOL_SIZE": "20",
            "DNS_CLUSTER_QUERY": "eventsales-app",
            "EVENTSALES_NODE_IP": NODE_IP,
            "WEBHOOK_REDIS_BUFFER_ENABLED": "false",
            "WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED": "false",
        }
        networks = data.get("networks", {})
        require(data.get("name") == "eventsales-app")
        require(sorted(data.get("services", {})) == ["app"])
        require("secrets" not in data)
        require(app.get("image") == APP_IMAGE)
        require(app.get("command") is None and app.get("entrypoint") is None)
        require("build" not in app and "ports" not in app)
        require(app.get("user") == "eventsales")
        require(app.get("init") is True)
        require(app.get("restart") == "unless-stopped")
        require(app.get("read_only") is True)
        require(app.get("cap_drop") == ["ALL"])
        require(app.get("cap_add", []) == [])
        require(app.get("privileged", False) is False)
        require(app.get("security_opt") == ["no-new-privileges:true"])
        require(app.get("cpus") == 4)
        require(is_memory(app.get("mem_limit"), {"2147483648", "2g", 2147483648}))
        require(app.get("pids_limit") == 512)
        require(app.get("tmpfs") == ["/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777"])
        require(app.get("expose") == ["4000"])
        require(app.get("volumes_from", []) == [])
        healthcheck = app.get("healthcheck", {})
        require(healthcheck.get("disable", False) is False)
        require(healthcheck.get("test") == ["CMD", "bin/event_sales", "pid"])
        require(app.get("environment") == environment)
        require("volumes" not in app)
        require(sorted(networks) == ["eventsales_data", "eventsales_edge"])
        require(networks["eventsales_data"].get("external") is True)
        require(networks["eventsales_data"].get("name") == "eventsales-prod_eventsales_data")
        require(networks["eventsales_edge"].get("external") is True)
        require(networks["eventsales_edge"].get("name") == "eventsales-prod_eventsales_edge")
        app_networks = app.get("networks", {})
        require(app_networks["eventsales_data"].get("aliases", []) == ["eventsales-app"])
        require(app_networks["eventsales_data"].get("ipv4_address") == NODE_IP)
        require(sorted(app_networks) == ["eventsales_data", "eventsales_edge"])
        require(app_networks["eventsales_edge"] == {})
    elif mode == "APP_INGRESS":
        app = read(paths[0])["services"]["app"]
        ports = app.get("ports", [])
        require(len(ports) == 1)
        port = ports[0]
        require(port.get("host_ip") == "127.0.0.1")
        require(port.get("target") in (4000, "4000"))
        require(port.get("published") in ("4100", 4100))
        require(port.get("protocol") == "tcp")
        require(port.get("mode", "ingress") == "ingress")
    else:
        raise ValueError


try:
    check(sys.argv[1], sys.argv[2:])
except Exception:
    sys.exit(1)
PY

python_check() {
  local check=$1
  shift
  if ! python3 "$TMP_DIR/contract_validator.py" "$check" "$@" >/dev/null 2>&1; then
    fail "$check"
  fi
}

python_check DATA_PLANE_JSON "$TMP_DIR/data-plane.json"
python_check APP_BASE_JSON "$TMP_DIR/app-base.json"
python_check APP_INGRESS_JSON "$TMP_DIR/app-ingress.json"
python_check APP_OVERLAY_EQUAL "$TMP_DIR/app-base.json" "$TMP_DIR/app-ingress.json"
python_check DATA_PROJECT "$TMP_DIR/data-plane.json"
python_check DATA_NETWORKS "$TMP_DIR/data-plane.json"
python_check DATA_NO_HOST_PORTS "$TMP_DIR/data-plane.json"
python_check DATA_VOLUME "$TMP_DIR/data-plane.json"
python_check DATA_SECRET_MOUNTS "$TMP_DIR/data-plane.json" "$TMP_DIR/secrets"

python_check POSTGRES_CONTRACT "$TMP_DIR/data-plane.json"
python_check PGBOUNCER_CONTAINER "$TMP_DIR/data-plane.json"
python_check REDIS_CONTAINER "$TMP_DIR/data-plane.json"

line_is_present "$NETWORK_SCRIPT" 'DATA_NETWORK=eventsales-prod_eventsales_data' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'EDGE_NETWORK=eventsales-prod_eventsales_edge' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'check_network "$DATA_NETWORK" true' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'check_network "$EDGE_NETWORK" false' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'provision_network "$DATA_NETWORK" true "$DATA_NETWORK_STATE"' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" 'provision_network "$EDGE_NETWORK" false "$EDGE_NETWORK_STATE"' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" '    if [[ "$expected_internal" == true ]]; then' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" '      docker network create --driver bridge --internal "$name" >/dev/null || {' || fail DATA_NETWORK_PROVISIONER
line_is_present "$NETWORK_SCRIPT" '      docker network create --driver bridge "$name" >/dev/null || {' || fail DATA_NETWORK_PROVISIONER
actual_network_script_sha256=$(sha256sum "$NETWORK_SCRIPT" | awk '{print $1}') || fail DATA_NETWORK_PROVISIONER
[[ "$actual_network_script_sha256" == "$NETWORK_SCRIPT_SHA256" ]] || fail DATA_NETWORK_PROVISIONER

python_check PGBOUNCER_SETTINGS "$PGBOUNCER_TEMPLATE"

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

python_check APP_BASE "$TMP_DIR/app-base.json"
python_check APP_INGRESS "$TMP_DIR/app-ingress.json"

printf 'VPS_DEPLOY_CONTRACT=PASS\n'
