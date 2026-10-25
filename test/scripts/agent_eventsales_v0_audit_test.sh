#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WRAPPER="$ROOT/deploy/vps/operator/agent-eventsales-v0-audit"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eventsales-v0-audit-test.XXXXXX")"
FAKE_BIN="$TMP_DIR/bin"
TEST_WRAPPER="$TMP_DIR/agent-eventsales-v0-audit"
mkdir -p "$FAKE_BIN"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local output=$1
  local expected=$2
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_not_contains() {
  local output=$1
  local forbidden=$2
  [[ "$output" != *"$forbidden"* ]] || fail "forbidden output found: $forbidden"
}

prepare_test_wrapper() {
  unset TEST_PATH
  [[ -f "$WRAPPER" ]] || fail "wrapper source is missing"
  local matches path_matches
  matches="$(grep -Fc 'readonly DOCKER=/usr/bin/docker' "$WRAPPER" || true)"
  [[ "$matches" == 1 ]] || fail "expected exactly one fixed Docker path for test-copy substitution"
  path_matches="$(grep -Fc 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$WRAPPER" || true)"
  [[ "$path_matches" == 1 ]] || fail "expected exactly one trusted PATH assignment for test-copy substitution"
  sed \
    -e 's|readonly DOCKER=/usr/bin/docker|readonly DOCKER=docker|' \
    -e 's|export PATH=/usr/sbin:/usr/bin:/sbin:/bin|export PATH="$PATH"|' \
    "$WRAPPER" > "$TEST_WRAPPER"
  case "${1:-}" in
    capture-small)
      [[ "$(grep -Fc 'MAX_TOTAL_CAPTURE_BYTES = 1048576' "$TEST_WRAPPER" || true)" == 1 ]] || fail "aggregate capture test limit anchor is missing"
      sed -i 's/MAX_TOTAL_CAPTURE_BYTES = 1048576/MAX_TOTAL_CAPTURE_BYTES = 128/' "$TEST_WRAPPER"
      ;;
    output-small)
      [[ "$(grep -Fc 'MAX_OUTPUT_BYTES = 131072' "$TEST_WRAPPER" || true)" == 1 ]] || fail "output test limit anchor is missing"
      sed -i 's/MAX_OUTPUT_BYTES = 131072/MAX_OUTPUT_BYTES = 1024/' "$TEST_WRAPPER"
      ;;
    line-small)
      [[ "$(grep -Fc 'MAX_LINE_BYTES = 1024' "$TEST_WRAPPER" || true)" == 1 ]] || fail "line test limit anchor is missing"
      sed -i 's/MAX_LINE_BYTES = 1024/MAX_LINE_BYTES = 38/' "$TEST_WRAPPER"
      ;;
    deadline-short)
      [[ "$(grep -Fc 'MAX_AUDIT_SECONDS = 120' "$TEST_WRAPPER" || true)" == 1 ]] || fail "audit deadline test limit anchor is missing"
      sed -i 's/MAX_AUDIT_SECONDS = 120/MAX_AUDIT_SECONDS = 1/' "$TEST_WRAPPER"
      ;;
    '') ;;
    *) fail "unknown test wrapper profile: $1" ;;
  esac
  chmod 700 "$TEST_WRAPPER"
}

make_fake_docker() {
  local mode=$1
  TEST_FAKE_DIR="$TMP_DIR/fake-$mode"
  mkdir -p "$TEST_FAKE_DIR"
  cat > "$TEST_FAKE_DIR/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
MODE="${0%/docker}"
MODE="${MODE##*/fake-}"
printf '%s\n' "$*" >> "${0%/docker}/calls.log"

[[ "${DOCKER_HOST:-}" == 'unix:///var/run/docker.sock' ]] || { printf 'FAKE_ENV_HOST_FAILED\n' >> "${0%/docker}/calls.log"; exit 89; }
[[ "${DOCKER_CONFIG:-}" == '/run/eventsales-v0-audit-no-docker-config' ]] || { printf 'FAKE_ENV_CONFIG_FAILED\n' >> "${0%/docker}/calls.log"; exit 88; }
[[ "${HOME:-}" == '/root' ]] || { printf 'FAKE_ENV_HOME_FAILED\n' >> "${0%/docker}/calls.log"; exit 87; }
for key in DOCKER_CONTEXT DOCKER_API_VERSION DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_TLS DOCKER_CUSTOM_HEADERS DOCKER_AUTH_CONFIG EVENTSALES_TEST_ENV_SENTINEL; do
  [[ -z "${!key+x}" ]] || { printf 'FAKE_ENV_UNSET_FAILED=%s\n' "$key" >> "${0%/docker}/calls.log"; exit 86; }
done

for arg in "$@"; do
  case "$arg" in
    create|run|start|stop|restart|rm|exec|up|down|connect|disconnect|prune)
      printf 'FAKE_MUTATION_VERB=%s\n' "$arg" >> "${0%/docker}/calls.log"
      exit 91
      ;;
  esac
done

if [[ "${1:-}" == version ]]; then
  [[ "${3:-}" == '{{.Server.APIVersion}}' ]] || exit 80
  [[ "$MODE" == *pool-unavailable* ]] && printf '1.40\n' || printf '1.51\n'
  exit 0
fi

if [[ "${1:-}" == info ]]; then
  [[ "$MODE" != info-failure ]] || exit 42
  case "${3:-}" in
    '{{.ServerVersion}}') [[ "$MODE" == info-sentinel ]] && printf 'SECRET_SENTINEL!\n' || printf '99.1.0\n' ;;
    '{{json .DefaultAddressPools}}')
      case "$MODE" in
        *custom-pool*) printf '[{"Base":"10.88.0.0/16","Size":24}]\n' ;;
        *pool-unavailable*) printf '<no value>\n' ;;
        *pool-many*) printf '['; for n in $(seq 1 33); do [[ "$n" == 1 ]] || printf ','; printf '{"Base":"10.%s.0.0/16","Size":24}' "$n"; done; printf ']\n' ;;
        *pool-malformed*) printf '[{"Base":"999.1.1.0/24","Size":99}]\n' ;;
        *) printf '[]\n' ;;
      esac
      ;;
    *) exit 81 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == ps ]]; then
  [[ " $* " == *' --no-trunc '* ]] || exit 92
  project="${5#label=com.docker.compose.project=}"
  case "$project" in
    eventsales-d0-proof)
      case "$MODE" in
        container-list-failure|custom-pool-container-list-failure) exit 50 ;;
        capture-overflow)
          head -c 120000 /dev/zero | tr '\000' x
          printf 'FAKE_CAPTURE_COMPLETED\n' >> "${0%/docker}/calls.log"
          ;;
        d0-many) for n in $(seq 1 17); do printf '%064d\n' "$n"; done ;;
        d0-missing) printf '%064d\n%064d\n' 1 3 ;;
        d0-duplicate) printf '%064d\n%064d\n%064d\n%064d\n' 1 2 3 4 ;;
        d0-extra) printf '%064d\n%064d\n%064d\n%064d\n' 1 2 3 5 ;;
        *) printf '%064d\n%064d\n%064d\n' 1 2 3 ;;
      esac
      ;;
    eventsales-prod)
      [[ "$MODE" != prod-container-list-failure ]] || exit 50
      [[ "$MODE" == prod-container ]] && printf '%064d\n' 6
      ;;
    eventsales-app)
      [[ "$MODE" != app-container-list-failure ]] || exit 50
      [[ "$MODE" == app-container ]] && printf '%064d\n' 7
      ;;
    *) exit 82 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == inspect && "${2:-}" == --type && "${3:-}" == container ]]; then
  [[ "${4:-}" == --format ]] || exit 85
  template="${5:-}"
  case "$template" in
    *'.Config.Env'*|*'.Args'*|*'.Path'*|*'.Mounts'*|*'HostConfig'*|*'LogPath'*|*'NetworkSettings.Networks'*) exit 83 ;;
  esac
  [[ "$MODE" != d0-inspect-failure ]] || exit 85
  for id in "${@:6}"; do
    service=postgres; name=/d0-postgres; image=postgres:18; state=running; health=healthy; restarts=0
    case "$id" in
      *0001) service=postgres; name=/d0-postgres; image=postgres:18 ;;
      *0002) service=pgbouncer; name=/d0-pgbouncer; image=pgbouncer:latest ;;
      *0003) service=redis; name=/d0-redis; image=redis:7 ;;
      *0004) service=postgres; name=/d0-postgres-duplicate; image=postgres:18 ;;
      *0005) service=probe; name=/d0-probe; image=busybox:latest ;;
      *) exit 84 ;;
    esac
    case "$MODE" in
      d0-stopped) [[ "$service" == postgres ]] && state=exited ;;
      d0-unhealthy) [[ "$service" == postgres ]] && health=unhealthy ;;
      d0-nohealth) [[ "$service" == postgres ]] && health=missing ;;
      d0-restarted) [[ "$service" == postgres ]] && restarts=1 ;;
    esac
    printf 'eventsales-d0-proof|%s|%s|%s|%s|%s|%s\n' "$service" "$name" "$image" "$state" "$health" "$restarts"
  done
  exit 0
fi

if [[ "${1:-}" == network && "${2:-}" == ls ]]; then
  case "$MODE" in
    network-list-failure) exit 85 ;;
    network-output-bound)
      for n in $(seq 100 227); do printf '%064d\n' "$n"; done
      ;;
    network-many)
      for n in $(seq 1 129); do printf 'n-%03d\n' "$n"; done
      ;;
    network-duplicate) printf '%064d\n%064d\n%064d\n%064d\n' 11 11 12 13 ;;
    network-d0-missing) printf '%064d\n%064d\n' 11 13 ;;
    network-d0-extra) printf '%064d\n%064d\n%064d\n%064d\n' 11 12 13 16 ;;
    network-data-present) printf '%064d\n%064d\n%064d\n%064d\n' 11 12 13 14 ;;
    network-edge-present) printf '%064d\n%064d\n%064d\n%064d\n' 11 12 13 15 ;;
    network-app-present) printf '%064d\n%064d\n%064d\n%064d\n' 11 12 13 17 ;;
    *) printf '%064d\n%064d\n%064d\n' 11 12 13 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == network && "${2:-}" == inspect ]]; then
  [[ "${3:-}" == --format ]] || exit 86
  id="${5:-}"
  template="${4:-}"
  case "$template" in
    *'.Containers'*|*'.Peers'*|*'MacAddress'*|*'EndpointID'*) exit 86 ;;
  esac
  if [[ "$MODE" == network-output-bound ]]; then
    padding="$(printf '%245s' '')"; padding="${padding// /x}"
    suffix="${id: -3}"
    subnet_parts=()
    for n in $(seq 0 15); do subnet_parts+=("10.1.$n.0/24"); done
    printf 'n%s%s|bridge|local|false|NONE|%s\n' "$padding" "$suffix" "$(IFS=';'; printf '%s' "${subnet_parts[*]}")"
    exit 0
  fi
  if [[ "$MODE" == network-slow && "${id: -4}" == 0011 ]]; then
    sleep 2
  fi
  if [[ "$MODE" == network-slow-closed-stdout && "${id: -4}" == 0011 ]]; then
    exec 1>&-
    sleep 2
    exit 0
  fi
  case "$id" in
    *0011)
      if [[ "$MODE" == network-malformed ]]; then
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|999.1.1.0/24\n'
      elif [[ "$MODE" == network-multi ]]; then
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|10.20.0.0/24;10.21.0.0/24;2001:db8:1::/64\n'
      elif [[ "$MODE" == network-duplicate-subnet ]]; then
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|10.20.0.0/24;10.20.0.0/24\n'
      elif [[ "$MODE" == network-ipam-many ]]; then
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|TOO_MANY\n'
      elif [[ "$MODE" == network-ipv6 ]]; then
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|2001:db8:1::/64\n'
      elif [[ "$MODE" == network-no-ipv4 ]]; then
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|NONE\n'
      elif [[ "$MODE" == network-inspect-failure ]]; then
        exit 87
      else
        printf 'd0-data|bridge|local|true|eventsales-d0-proof|10.20.0.0/24\n'
      fi
      ;;
    *0012) printf 'd0-edge|bridge|local|false|eventsales-d0-proof|10.22.0.0/24\n' ;;
    *0013) printf 'bridge|bridge|local|false|NONE|172.17.0.0/16\n' ;;
    *0014) printf 'eventsales-prod_eventsales_data|bridge|local|true|eventsales-prod|10.30.0.0/24\n' ;;
    *0015) printf 'eventsales-prod_eventsales_edge|bridge|local|false|eventsales-prod|10.31.0.0/24\n' ;;
    *0016) printf 'd0-extra|bridge|local|false|eventsales-d0-proof|10.23.0.0/24\n' ;;
    *0017) printf 'eventsales-app_eventsales_edge|bridge|local|false|eventsales-app|10.32.0.0/24\n' ;;
    *) exit 85 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == volume && "${2:-}" == ls ]]; then
  [[ "${5:-}" == --format ]] || exit 87
  filter="${4:-}"
  if [[ "$filter" == label=com.docker.compose.project=eventsales-d0-proof ]]; then
    if [[ "$MODE" == volume-list-failure ]]; then
      exit 87
    elif [[ "$MODE" == volume-malformed ]]; then
      printf 'd0-data|bad/driver|eventsales-d0-proof\n'
    elif [[ "$MODE" == volume-many ]]; then
      for n in $(seq 1 17); do printf 'd0-%s|local|eventsales-d0-proof\n' "$n"; done
    elif [[ "$MODE" == volume-extra ]]; then
      printf 'd0-data|local|eventsales-d0-proof\nd0-extra|local|eventsales-d0-proof\n'
    else
      printf 'd0-data|local|eventsales-d0-proof\n'
    fi
  elif [[ "$filter" == label=com.docker.compose.project=eventsales-prod && "$MODE" == prod-volume ]]; then
    printf 'unexpected\n'
  elif [[ "$filter" == label=com.docker.compose.project=eventsales-app && "$MODE" == app-volume ]]; then
    printf 'unexpected-app\n'
  elif [[ "$filter" == name=eventsales-prod_postgres_data && "$MODE" == prod-volume ]]; then
    printf 'eventsales-prod_postgres_data\n'
  fi
  exit 0
fi

printf 'FAKE_DOCKER_UNEXPECTED_COMMAND=%s\n' "$*" >> "${0%/docker}/calls.log"
printf 'FAKE_DOCKER_UNEXPECTED_COMMAND\n' >&2
exit 90
FAKE_DOCKER
  chmod 700 "$TEST_FAKE_DIR/docker"
}

run_wrapper() {
  local test_path="${TEST_PATH:-$TEST_FAKE_DIR:/usr/bin:/bin}"
  : > "$TMP_DIR/stdout"
  : > "$TMP_DIR/stderr"
  set +e
  DOCKER_HOST=caller-host-sentinel \
  DOCKER_CONTEXT=caller-context-sentinel \
  DOCKER_CONFIG=caller-config-sentinel \
  DOCKER_API_VERSION=caller-api-sentinel \
  DOCKER_TLS_VERIFY=caller-tls-sentinel \
  DOCKER_CERT_PATH=caller-cert-sentinel \
  DOCKER_TLS=caller-tls-mode-sentinel \
  DOCKER_CUSTOM_HEADERS=caller-header-sentinel \
  DOCKER_AUTH_CONFIG=caller-auth-sentinel \
  EVENTSALES_TEST_ENV_SENTINEL=caller-env-sentinel \
  HOME=caller-home-sentinel \
  PATH="$test_path" /usr/bin/bash "$TEST_WRAPPER" "$@" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr"
  TEST_STATUS=$?
  set -e
  TEST_OUTPUT="$(cat "$TMP_DIR/stdout")"
  TEST_STDERR="$(cat "$TMP_DIR/stderr")"
  TEST_DOCKER_LOG=""
  if [[ -f "$TEST_FAKE_DIR/calls.log" ]]; then
    TEST_DOCKER_LOG="$(cat "$TEST_FAKE_DIR/calls.log")"
  fi
}

test_arguments() {
  prepare_test_wrapper
  make_fake_docker healthy
  run_wrapper unexpected
  [[ "$TEST_STATUS" -eq 2 ]] || fail "argument rejection exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT$TEST_STDERR" 'STOP=ARGUMENTS_NOT_ALLOWED'
  [[ -z "$TEST_DOCKER_LOG" ]] || fail "Docker ran before argument rejection"
  printf 'PASS arguments\n'
}

test_docker_unavailable() {
  prepare_test_wrapper
  mkdir -p "$TMP_DIR/empty-bin"
  TEST_FAKE_DIR="$TMP_DIR/empty-bin"
  TEST_PATH="$TMP_DIR/empty-bin"
  run_wrapper
  [[ "$TEST_STATUS" -eq 127 ]] || fail "missing Docker exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'EVENTSALES_V0_DOCKER_AUDIT_VERSION=1'
  assert_contains "$TEST_OUTPUT" 'AUDIT_MUTATION=NONE'
  assert_contains "$TEST_OUTPUT" 'SECRETS_REQUESTED=NO'
  assert_contains "$TEST_OUTPUT" 'STOP=DOCKER_CLI_UNAVAILABLE'
  printf 'PASS unavailable Docker\n'
}

test_healthy_audit() {
  prepare_test_wrapper
  make_fake_docker healthy
  run_wrapper
  [[ "$TEST_STATUS" -eq 0 ]] || fail "healthy audit exit was $TEST_STATUS: $TEST_OUTPUT $TEST_STDERR"
  assert_contains "$TEST_OUTPUT" 'DOCKER_SERVER_VERSION=99.1.0'
  assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_SOURCE=BUILTIN'
  assert_contains "$TEST_OUTPUT" 'D0_CONTAINER_COUNT=3'
  assert_contains "$TEST_OUTPUT" 'D0_CONTAINER_1_SERVICE=postgres'
  assert_contains "$TEST_OUTPUT" 'D0_CONTAINER_2_SERVICE=pgbouncer'
  assert_contains "$TEST_OUTPUT" 'D0_CONTAINER_3_SERVICE=redis'
  assert_contains "$TEST_OUTPUT" 'D0_NETWORK_1_INTERNAL=true'
  assert_contains "$TEST_OUTPUT" 'D0_NETWORK_2_INTERNAL=false'
  assert_contains "$TEST_OUTPUT" 'AUDIT_RESULT=PASS'
  for sentinel in caller-host-sentinel caller-context-sentinel caller-config-sentinel caller-api-sentinel caller-tls-sentinel caller-cert-sentinel caller-header-sentinel caller-auth-sentinel caller-env-sentinel caller-home-sentinel; do
    assert_not_contains "$TEST_OUTPUT$TEST_STDERR" "$sentinel"
  done
  for sentinel in SECRET_SENTINEL ENV_SENTINEL ARGV_SENTINEL COMMAND_SENTINEL ENDPOINT_SENTINEL MAC_SENTINEL MOUNTPOINT_SENTINEL LOG_SENTINEL; do
    assert_not_contains "$TEST_OUTPUT$TEST_STDERR" "$sentinel"
  done
  for forbidden in 'create' 'run' 'start' 'stop' 'restart' 'rm' 'exec' 'up' 'down' 'connect' 'disconnect' 'prune' 'logs'; do
    [[ "$TEST_DOCKER_LOG" != *" $forbidden"* ]] || fail "forbidden Docker verb logged: $forbidden"
  done
  while IFS= read -r command; do
    if [[ "$command" == *' inspect '* ]]; then
      [[ "$command" == *' --format '* ]] || fail "unformatted inspect logged"
    fi
  done <<< "$TEST_DOCKER_LOG"
  for forbidden in '.Config.Env' '.Args' '.Path' '.Mounts' 'Mountpoint' '.Containers' 'MacAddress' 'EndpointID'; do
    [[ "$TEST_DOCKER_LOG" != *"$forbidden"* ]] || fail "forbidden Docker field requested: $forbidden"
  done
  assert_not_contains "$TEST_DOCKER_LOG" 'FAKE_MUTATION_VERB='
  printf 'PASS healthy audit\n'
}

test_secret_sentinel() {
  prepare_test_wrapper
  make_fake_docker info-sentinel
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "sentinel metadata exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=DOCKER_INFO_FAILED'
  assert_not_contains "$TEST_OUTPUT$TEST_STDERR" 'SECRET_SENTINEL!'
  printf 'PASS secret sentinel suppression\n'
}

test_production_container_list_failures() {
  local mode
  for mode in prod-container-list-failure app-container-list-failure; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    assert_contains "$TEST_OUTPUT" 'STOP=PRODUCTION_CONTAINER_LIST_FAILED'
  done
  printf 'PASS production container list failures\n'
}

test_capture_bound_early_abort() {
  prepare_test_wrapper capture-small
  make_fake_docker capture-overflow
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "capture overflow exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=OUTPUT_BOUND_EXCEEDED'
  assert_not_contains "$TEST_DOCKER_LOG" 'FAKE_CAPTURE_COMPLETED'
  printf 'PASS aggregate capture stops early\n'
}

test_output_bounds_and_deadline() {
  local profile
  for profile in capture-small output-small line-small; do
    prepare_test_wrapper "$profile"
    make_fake_docker healthy
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$profile exit was $TEST_STATUS"
    assert_contains "$TEST_OUTPUT" 'STOP=OUTPUT_BOUND_EXCEEDED'
  done

  prepare_test_wrapper deadline-short
  make_fake_docker network-slow
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "global deadline exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=DOCKER_AUDIT_TIMEOUT'

  prepare_test_wrapper deadline-short
  make_fake_docker network-slow-closed-stdout
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "closed-stdout deadline exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=DOCKER_AUDIT_TIMEOUT'

  test_capture_bound_early_abort
  printf 'PASS output bounds and audit deadline\n'
}

test_info_failure() {
  prepare_test_wrapper
  make_fake_docker info-failure
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "info failure exit was $TEST_STATUS: $TEST_OUTPUT $TEST_STDERR"
  assert_contains "$TEST_OUTPUT" 'STOP=DOCKER_INFO_FAILED'
  printf 'PASS info failure\n'
}

test_pool_contract() {
  local mode
  for mode in container-list-failure custom-pool-container-list-failure; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    assert_contains "$TEST_OUTPUT" 'STOP=D0_CONTAINER_LIST_FAILED'
    assert_contains "$TEST_OUTPUT" 'DOCKER_SERVER_VERSION=99.1.0'
    if [[ "$mode" == custom-pool-container-list-failure ]]; then
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_SOURCE=CUSTOM'
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_1_BASE=10.88.0.0/16'
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_1_PREFIX_SIZE=24'
    else
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_SOURCE=BUILTIN'
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_COUNT=7'
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_1_BASE=172.17.0.0/16'
      assert_contains "$TEST_OUTPUT" 'DEFAULT_ADDRESS_POOL_7_PREFIX_SIZE=20'
    fi
  done

  for mode in pool-unavailable pool-malformed; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    if [[ "$mode" == pool-unavailable ]]; then
      assert_contains "$TEST_OUTPUT" 'STOP=DEFAULT_ADDRESS_POOLS_UNAVAILABLE'
    else
      assert_contains "$TEST_OUTPUT" 'STOP=DEFAULT_ADDRESS_POOLS_MALFORMED'
    fi
    [[ "$TEST_DOCKER_LOG" != *'ps -a'* ]] || fail "container query ran after pool STOP"
    assert_contains "$TEST_DOCKER_LOG" 'info --format {{json .DefaultAddressPools}}'
  done
  prepare_test_wrapper
  make_fake_docker pool-many
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "pool-many exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=OUTPUT_BOUND_EXCEEDED'
  printf 'PASS address pool contract\n'
}

test_d0_guards() {
  local mode expected
  for mode in d0-missing d0-duplicate d0-extra; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    assert_contains "$TEST_OUTPUT" 'STOP=D0_SERVICE_SET_MISMATCH'
  done

  prepare_test_wrapper
  make_fake_docker d0-many
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "d0-many exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=OUTPUT_BOUND_EXCEEDED'

  prepare_test_wrapper
  make_fake_docker d0-inspect-failure
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "D0 inspect failure exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=D0_CONTAINER_INSPECT_FAILED'

  for mode in d0-stopped d0-unhealthy d0-nohealth d0-restarted; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    case "$mode" in
      d0-stopped) expected=D0_CONTAINER_NOT_RUNNING ;;
      d0-unhealthy|d0-nohealth) expected=D0_CONTAINER_UNHEALTHY ;;
      d0-restarted) expected=D0_RESTART_COUNT_NONZERO ;;
    esac
    assert_contains "$TEST_OUTPUT" "STOP=$expected"
  done
  printf 'PASS D0 service, health, and restart guards\n'
}

test_network_contract() {
  local mode expected
  for mode in network-multi network-ipv6 network-no-ipv4; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 0 ]] || fail "$mode exit was $TEST_STATUS: $TEST_OUTPUT stderr=$TEST_STDERR calls=$TEST_DOCKER_LOG"
    assert_contains "$TEST_OUTPUT" 'AUDIT_RESULT=PASS'
    assert_contains "$TEST_OUTPUT" 'D0_NETWORK_COUNT=2'
    if [[ "$mode" == network-multi ]]; then
      assert_contains "$TEST_OUTPUT" '10.20.0.0/24'
      assert_contains "$TEST_OUTPUT" '10.21.0.0/24'
      assert_contains "$TEST_OUTPUT" 'D0_NETWORK_1_IPV6_PRESENT=YES'
    elif [[ "$mode" == network-ipv6 ]]; then
      assert_contains "$TEST_OUTPUT" 'BRIDGE_NETWORK_2_IPV6_PRESENT=YES'
      assert_contains "$TEST_OUTPUT" 'BRIDGE_NETWORK_2_IPV4_SUBNET_COUNT=0'
    else
      assert_contains "$TEST_OUTPUT" 'BRIDGE_NETWORK_2_IPV6_PRESENT=NO'
      assert_contains "$TEST_OUTPUT" 'BRIDGE_NETWORK_2_IPV4_SUBNET_COUNT=0'
    fi
  done

  for mode in network-malformed network-duplicate network-duplicate-subnet network-ipam-many network-inspect-failure network-list-failure network-d0-missing network-d0-extra network-many network-output-bound; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    case "$mode" in
      network-malformed|network-duplicate|network-duplicate-subnet) expected=NETWORK_METADATA_MALFORMED ;;
      network-ipam-many|network-many) expected=OUTPUT_BOUND_EXCEEDED ;;
      network-output-bound) expected=OUTPUT_BOUND_EXCEEDED ;;
      network-list-failure) expected=NETWORK_LIST_FAILED ;;
      network-inspect-failure) expected=NETWORK_INSPECT_FAILED ;;
      network-d0-missing|network-d0-extra) expected=D0_NETWORK_SET_MISMATCH ;;
    esac
    assert_contains "$TEST_OUTPUT" "STOP=$expected"
  done

  for mode in network-data-present network-edge-present network-app-present; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS: $TEST_OUTPUT"
    [[ "$TEST_OUTPUT" == *'STOP=UNEXPECTED_PREEXISTING_PRODUCTION_OBJECT'* ]] || fail "$mode expected production-object STOP: $TEST_OUTPUT"
  done
  printf 'PASS network and subnet contract\n'
}

test_volume_and_production_contract() {
  local mode
  prepare_test_wrapper
  make_fake_docker healthy
  run_wrapper
  [[ "$TEST_STATUS" -eq 0 ]] || fail "healthy volume audit exit was $TEST_STATUS: $TEST_OUTPUT"
  assert_contains "$TEST_OUTPUT" 'D0_VOLUME_COUNT=1'
  assert_contains "$TEST_OUTPUT" 'D0_VOLUME_1_NAME=d0-data'
  assert_contains "$TEST_OUTPUT" 'D0_VOLUME_1_DRIVER=local'
  assert_contains "$TEST_OUTPUT" 'D0_VOLUME_1_PROJECT=eventsales-d0-proof'
  assert_contains "$TEST_OUTPUT" 'EVENTSALES_PROD_PROJECT_OBJECTS_ABSENT=YES'
  assert_contains "$TEST_OUTPUT" 'EVENTSALES_APP_PROJECT_OBJECTS_ABSENT=YES'
  assert_contains "$TEST_OUTPUT" 'PROD_POSTGRES_VOLUME_ABSENT=YES'
  assert_not_contains "$TEST_OUTPUT$TEST_STDERR" 'Mountpoint'

  prepare_test_wrapper
  make_fake_docker volume-extra
  run_wrapper
  [[ "$TEST_STATUS" -eq 1 ]] || fail "extra D0 volume exit was $TEST_STATUS"
  assert_contains "$TEST_OUTPUT" 'STOP=D0_VOLUME_SET_MISMATCH'

  for mode in volume-list-failure volume-malformed volume-many; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS"
    case "$mode" in
      volume-list-failure) assert_contains "$TEST_OUTPUT" 'STOP=VOLUME_LIST_FAILED' ;;
      volume-malformed) assert_contains "$TEST_OUTPUT" 'STOP=VOLUME_METADATA_MALFORMED' ;;
      volume-many) assert_contains "$TEST_OUTPUT" 'STOP=OUTPUT_BOUND_EXCEEDED' ;;
    esac
  done

  for mode in prod-container app-container prod-volume app-volume; do
    prepare_test_wrapper
    make_fake_docker "$mode"
    run_wrapper
    [[ "$TEST_STATUS" -eq 1 ]] || fail "$mode exit was $TEST_STATUS: $TEST_OUTPUT"
    [[ "$TEST_OUTPUT" == *'STOP=UNEXPECTED_PREEXISTING_PRODUCTION_OBJECT'* ]] || fail "$mode expected production-object STOP: $TEST_OUTPUT"
  done
  printf 'PASS volume and production-object contract\n'
}

case "${1:-all}" in
  arguments) test_arguments ;;
  docker-unavailable) test_docker_unavailable ;;
  healthy) test_healthy_audit ;;
  info-failure) test_info_failure ;;
  pools) test_pool_contract ;;
  d0) test_d0_guards ;;
  networks) test_network_contract ;;
  volumes) test_volume_and_production_contract ;;
  output-bounds) test_output_bounds_and_deadline ;;
  capture-bound) test_capture_bound_early_abort ;;
  secret-sentinel) test_secret_sentinel ;;
  production-container-list-failures) test_production_container_list_failures ;;
  all) test_arguments; test_docker_unavailable; test_info_failure; test_pool_contract; test_d0_guards; test_network_contract; test_volume_and_production_contract; test_output_bounds_and_deadline; test_secret_sentinel; test_production_container_list_failures; test_healthy_audit ;;
  *) fail "unknown test selection: $1" ;;
esac
