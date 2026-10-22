#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../../../" && pwd -P)
IMAGE_DIR="$REPO_ROOT/deploy/vps/data-plane/pgbouncer-image"
RUST_BUILDER='rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9'
LOCAL_IMAGE_TAG='eventsales-pgbouncer:r3-4-local'
SOURCE_URL='https://github.com/JCSchoeman96/EventSales'
PROBE_PATH='/usr/local/bin/eventsales-pgbouncer-healthcheck'

RUN_DIR=''
RUN_ID=''
TMP_ROOT=''
UNIT_CONTAINER_ID=''
CANDIDATE_CONTAINER_ID=''
HELPER_CONTAINER_ID=''
HELPER_BUILD_CONTAINER_NAME=''
NETWORK_ID=''
NETWORK_NAME=''
CANDIDATE_IMAGE_ID=''

usage() {
  printf 'Usage: bash %s <unit|build|static|integration|self-test|all> [image-reference]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

create_run_context() {
  local mode=$1
  TMP_ROOT=${TMPDIR:-/tmp}
  [[ -d "$TMP_ROOT" && -w "$TMP_ROOT" ]] || fail "temporary root is not writable: $TMP_ROOT"
  TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P)
  RUN_DIR=$(mktemp -d "$TMP_ROOT/eventsales-r3-4-proof.XXXXXX")
  RUN_ID=${RUN_DIR##*.}
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'PROOF_MODE=%s\nPROOF_RUN_ID=%s\n' "$mode" "$RUN_ID"
}

cleanup() {
  local original_status=$?
  local cleanup_failed=0
  local helper_build_id=''
  local helper_build_run_id=''
  trap - EXIT INT TERM

  if [[ -n "$UNIT_CONTAINER_ID" ]]; then
    docker rm -f "$UNIT_CONTAINER_ID" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -n "$CANDIDATE_CONTAINER_ID" ]]; then
    docker rm -f "$CANDIDATE_CONTAINER_ID" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -n "$HELPER_CONTAINER_ID" ]]; then
    docker rm -f "$HELPER_CONTAINER_ID" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -n "$HELPER_BUILD_CONTAINER_NAME" ]]; then
    if [[ "$HELPER_BUILD_CONTAINER_NAME" != "eventsales-r3-4-${RUN_ID}-http-build" ]]; then
      printf 'Refusing to remove unexpected helper-build container name: %s\n' "$HELPER_BUILD_CONTAINER_NAME" >&2
      cleanup_failed=1
    elif helper_build_id=$(docker container inspect --format '{{.Id}}' "$HELPER_BUILD_CONTAINER_NAME" 2>/dev/null); then
      helper_build_run_id=$(docker container inspect --format '{{index .Config.Labels "eventsales.r3-4.proof-run"}}' "$helper_build_id" 2>/dev/null) || helper_build_run_id=''
      if [[ "$helper_build_run_id" == "$RUN_ID" ]]; then
        if ! docker rm -f "$helper_build_id" >/dev/null 2>&1; then
          if docker container inspect "$helper_build_id" >/dev/null 2>&1; then
            cleanup_failed=1
          fi
        fi
      else
        printf 'Refusing to remove helper-build container without this run label: %s\n' "$HELPER_BUILD_CONTAINER_NAME" >&2
        cleanup_failed=1
      fi
    elif ! docker info >/dev/null 2>&1; then
      printf 'Unable to inspect helper-build container during cleanup: %s\n' "$HELPER_BUILD_CONTAINER_NAME" >&2
      cleanup_failed=1
    fi
  fi
  if [[ -n "$NETWORK_ID" ]]; then
    docker network rm "$NETWORK_ID" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    case "$RUN_DIR" in
      "$TMP_ROOT"/eventsales-r3-4-proof.*)
        if ((original_status == 0 && cleanup_failed == 0)); then
          rm -rf -- "$RUN_DIR" || cleanup_failed=1
        fi
        ;;
      *)
        printf 'Refusing to remove unexpected temporary path: %s\n' "$RUN_DIR" >&2
        cleanup_failed=1
        ;;
    esac
  fi

  if ((cleanup_failed)); then
    printf 'TASK3_CLEANUP=FAIL\n' >&2
    if ((original_status == 0)); then
      original_status=1
    fi
  fi
  if ((original_status != 0)) && [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    printf 'FAILURE_EVIDENCE_DIR=%s\n' "$RUN_DIR"
  fi
  exit "$original_status"
}

run_unit() {
  create_run_context unit
  local unit_name="eventsales-r3-4-unit-$RUN_ID"
  UNIT_CONTAINER_ID=$(docker create \
    --name "$unit_name" \
    --platform linux/amd64 \
    --network none \
    --mount "type=bind,src=$IMAGE_DIR,dst=/src,readonly" \
    "$RUST_BUILDER" \
    /bin/sh -ec 'rustc --edition=2021 --test --target x86_64-unknown-linux-musl /src/eventsales_pgbouncer_healthcheck.rs -o /tmp/probe-tests && /tmp/probe-tests')
  timeout 30s docker start --attach "$UNIT_CONTAINER_ID"
  printf 'UNIT_MODE=PASS\n'
}

run_build() {
  create_run_context build
  local source_revision
  local built_image_id
  source_revision=$(git -C "$REPO_ROOT" rev-parse HEAD)
  docker build \
    --platform linux/amd64 \
    -f "$IMAGE_DIR/Dockerfile" \
    -t "$LOCAL_IMAGE_TAG" \
    --build-arg "SOURCE_URL=$SOURCE_URL" \
    --build-arg "VCS_REF=$source_revision" \
    "$IMAGE_DIR"
  built_image_id=$(docker image inspect --format '{{.Id}}' "$LOCAL_IMAGE_TAG")
  printf 'BUILD_MODE=PASS\nBUILT_IMAGE_TAG=%s\nBUILT_IMAGE_ID=%s\n' "$LOCAL_IMAGE_TAG" "$built_image_id"
}

inspect_candidate_hardening() {
  local fields
  local actual_user
  local read_only
  local nano_cpus
  local memory
  local cap_drop
  local security_options
  local network_mode
  local port_bindings
  local publish_all_ports
  local tmpfs
  local network_internal
  local network_names

  fields=$(docker inspect --format '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}|{{.HostConfig.NetworkMode}}|{{json .HostConfig.PortBindings}}|{{.HostConfig.PublishAllPorts}}|{{json .HostConfig.Tmpfs}}' "$CANDIDATE_CONTAINER_ID")
  IFS='|' read -r actual_user read_only nano_cpus memory cap_drop security_options network_mode port_bindings publish_all_ports tmpfs <<< "$fields"

  [[ "$actual_user" == '65532:65532' ]] || fail "candidate user differs: $actual_user"
  [[ "$read_only" == 'true' ]] || fail 'candidate root filesystem is not read-only'
  [[ "$nano_cpus" == '500000000' ]] || fail "candidate CPU limit differs: $nano_cpus"
  [[ "$memory" == '134217728' ]] || fail "candidate memory limit differs: $memory"
  [[ "$cap_drop" == '["ALL"]' ]] || fail "candidate capabilities were not all dropped: $cap_drop"
  [[ "$security_options" == '["no-new-privileges:true"]' ]] || fail "candidate no-new-privileges setting differs: $security_options"
  [[ "$network_mode" == "$NETWORK_NAME" ]] || fail "candidate network mode differs: $network_mode"
  [[ "$port_bindings" == 'null' || "$port_bindings" == '{}' ]] || fail "candidate has host port bindings: $port_bindings"
  [[ "$publish_all_ports" == 'false' ]] || fail 'candidate publishes exposed ports'
  [[ "$tmpfs" == *'"/tmp"'* ]] || fail 'candidate lacks a bounded /tmp tmpfs'

  network_internal=$(docker network inspect --format '{{.Internal}}' "$NETWORK_ID")
  [[ "$network_internal" == 'true' ]] || fail 'candidate test network is not internal'
  network_names=$(docker inspect --format '{{range $name, $endpoint := .NetworkSettings.Networks}}{{$name}} {{end}}' "$CANDIDATE_CONTAINER_ID")
  network_names=${network_names% }
  [[ "$network_names" == "$NETWORK_NAME" ]] || fail "candidate has unexpected network attachments: $network_names"

  printf 'PGBOUNCER_CONTAINER_HARDENING=PASS\n'
  printf 'USER_65532=PASS\nREAD_ONLY_ROOTFS=PASS\nCPU_0_5=PASS\nMEMORY_128M=PASS\nCAP_DROP_ALL=PASS\nNO_NEW_PRIVILEGES=PASS\nNO_HOST_PORTS=PASS\nINTERNAL_TEST_NETWORK_ONLY=PASS\n'
}

start_and_wait_for_log() {
  local container_id=$1
  local startup_seconds=$2
  local ready_text=$3
  timeout "${startup_seconds}s" bash -c '
    container_id=$1
    ready_text=$2
    docker start "$container_id" >/dev/null
    while :; do
      running=$(docker inspect --format "{{.State.Running}}" "$container_id" 2>/dev/null || printf false)
      if [[ "$running" != true ]]; then
        docker logs "$container_id" >&2 || true
        exit 1
      fi
      logs=$(docker logs "$container_id" 2>&1 || true)
      if [[ "$logs" == *"$ready_text"* ]]; then
        printf "READY_EVIDENCE=%s\n" "$ready_text"
        exit 0
      fi
      sleep 0.1
    done
  ' _ "$container_id" "$ready_text"
}

run_integration() {
  local image_reference=$1
  local candidate_name
  local helper_name
  local helper_compile_name
  local helper_ip
  local helper_fields
  local helper_network_mode
  local helper_port_bindings
  local positive_status
  local listener_down_status
  local non_postgres_status

  create_run_context integration
  command -v timeout >/dev/null 2>&1 || fail 'timeout utility is required for bounded proof waits'

  CANDIDATE_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$image_reference")
  [[ -n "$CANDIDATE_IMAGE_ID" ]] || fail "image reference did not resolve: $image_reference"
  local candidate_platform
  candidate_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$CANDIDATE_IMAGE_ID")
  [[ "$candidate_platform" == 'linux/amd64' ]] || fail "candidate platform must be linux/amd64, got: $candidate_platform"
  printf 'CANDIDATE_IMAGE_ID=%s\n' "$CANDIDATE_IMAGE_ID"
  printf 'CANDIDATE_PLATFORM=linux/amd64\n'

  NETWORK_NAME="eventsales-r3-4-$RUN_ID"
  candidate_name="eventsales-r3-4-$RUN_ID-candidate"
  helper_name="eventsales-r3-4-$RUN_ID-http"
  helper_compile_name="eventsales-r3-4-$RUN_ID-http-build"
  NETWORK_ID=$(docker network create --internal --driver bridge "$NETWORK_NAME")

  cat > "$RUN_DIR/pgbouncer.ini" <<'PGBOUNCER'
[databases]
synthetic_fixture_db = host=127.0.0.1 port=6543 dbname=synthetic_fixture_db

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/users.txt
pool_mode = transaction
max_client_conn = 64
default_pool_size = 12
reserve_pool_size = 4
max_db_connections = 16
max_user_connections = 16
max_prepared_statements = 200
pidfile = /tmp/pgbouncer.pid
unix_socket_dir = /tmp
PGBOUNCER

  cat > "$RUN_DIR/auth_file" <<'AUTH'
"r3_4_probe_user" "SCRAM-SHA-256$4096:c3ludGhldGljLXNhbHQ=$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
AUTH
  chmod 0444 "$RUN_DIR/pgbouncer.ini" "$RUN_DIR/auth_file"

  CANDIDATE_CONTAINER_ID=$(docker create \
    --name "$candidate_name" \
    --network "$NETWORK_NAME" \
    --user 65532:65532 \
    --read-only \
    --cpus 0.5 \
    --memory 128m \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
    --mount "type=bind,src=$RUN_DIR/pgbouncer.ini,dst=/etc/pgbouncer/pgbouncer.ini,readonly" \
    --mount "type=bind,src=$RUN_DIR/auth_file,dst=/etc/pgbouncer/users.txt,readonly" \
    "$CANDIDATE_IMAGE_ID")

  if ! start_and_wait_for_log "$CANDIDATE_CONTAINER_ID" 10 'listening on 0.0.0.0:6432'; then
    fail 'PgBouncer listener did not report startup within 10 seconds'
  fi
  inspect_candidate_hardening

  cat > "$RUN_DIR/http-listener.rs" <<'RUST'
use std::io::Write;
use std::net::TcpListener;

fn main() {
    let listener = TcpListener::bind(("0.0.0.0", 6433)).expect("bind fake HTTP listener");
    println!("FAKE_HTTP_LISTENER_READY");
    let (mut stream, _) = listener.accept().expect("accept probe connection");
    stream
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        .expect("write fixed HTTP response");
}
RUST

  HELPER_BUILD_CONTAINER_NAME=$helper_compile_name
  local helper_build_status=0
  timeout --signal=KILL 30s docker run --rm \
    --name "$HELPER_BUILD_CONTAINER_NAME" \
    --label "eventsales.r3-4.proof-run=$RUN_ID" \
    --platform linux/amd64 \
    --network none \
    --mount "type=bind,src=$RUN_DIR,dst=/work" \
    "$RUST_BUILDER" \
    rustc --edition=2021 --target x86_64-unknown-linux-musl /work/http-listener.rs -o /work/http-listener \
    > "$RUN_DIR/helper-build.log" 2>&1 || helper_build_status=$?
  if ((helper_build_status != 0)); then
    cat "$RUN_DIR/helper-build.log" >&2
    fail "HTTP helper compilation failed or exceeded 30 seconds (exit $helper_build_status)"
  fi

  helper_name="eventsales-r3-4-$RUN_ID-http"
  HELPER_CONTAINER_ID=$(docker create \
    --name "$helper_name" \
    --platform linux/amd64 \
    --network "$NETWORK_NAME" \
    --user 65532:65532 \
    --read-only \
    --cpus 0.25 \
    --memory 64m \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --mount "type=bind,src=$RUN_DIR/http-listener,dst=/tmp/http-listener,readonly" \
    --entrypoint /tmp/http-listener \
    "$RUST_BUILDER")

  helper_fields=$(docker inspect --format '{{.HostConfig.NetworkMode}}|{{json .HostConfig.PortBindings}}' "$HELPER_CONTAINER_ID")
  IFS='|' read -r helper_network_mode helper_port_bindings <<< "$helper_fields"
  [[ "$helper_network_mode" == "$NETWORK_NAME" ]] || fail 'HTTP helper is outside the unique internal network'
  [[ "$helper_port_bindings" == 'null' || "$helper_port_bindings" == '{}' ]] || fail 'HTTP helper has host port bindings'
  if ! start_and_wait_for_log "$HELPER_CONTAINER_ID" 5 'FAKE_HTTP_LISTENER_READY'; then
    fail 'non-PostgreSQL helper did not become ready within five seconds'
  fi

  helper_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$HELPER_CONTAINER_ID")
  [[ "$helper_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "helper IP is not a numeric IPv4 address: $helper_ip"
  printf 'NON_POSTGRES_HELPER_NUMERIC_IP=%s\n' "$helper_ip"

  positive_status=0
  if timeout 5s docker exec "$CANDIDATE_CONTAINER_ID" "$PROBE_PATH" 127.0.0.1 6432 r3_4_probe_user > "$RUN_DIR/positive.log" 2>&1; then
    positive_status=0
  else
    positive_status=$?
  fi
  [[ "$positive_status" -eq 0 ]] || {
    cat "$RUN_DIR/positive.log" >&2
    fail "known synthetic PgBouncer user probe returned $positive_status"
  }
  printf 'REAL_PGBOUNCER_PROBE=PASS\nEXPECTED_RESPONSE_CLASS=R/10/SCRAM-SHA-256\nPOSITIVE_EXIT_CODE=0\n'
  printf 'BACKEND_POSTGRES_STARTED=NO\nBACKEND_CONNECTION_REQUIRED_FOR_PASS=NO\n'

  if timeout 5s docker exec "$CANDIDATE_CONTAINER_ID" "$PROBE_PATH" 127.0.0.1 6499 r3_4_probe_user > "$RUN_DIR/listener-down.log" 2>&1; then
    listener_down_status=0
  else
    listener_down_status=$?
  fi
  [[ "$listener_down_status" -ne 0 && "$listener_down_status" -ne 124 ]] || {
    cat "$RUN_DIR/listener-down.log" >&2
    fail "listener-down probe did not fail promptly (exit $listener_down_status)"
  }
  printf 'LISTENER_DOWN_TEST=PASS\nLISTENER_DOWN_EXIT_CODE=%s\n' "$listener_down_status"

  if timeout 5s docker exec "$CANDIDATE_CONTAINER_ID" "$PROBE_PATH" "$helper_ip" 6433 r3_4_probe_user > "$RUN_DIR/non-postgres.log" 2>&1; then
    non_postgres_status=0
  else
    non_postgres_status=$?
  fi
  [[ "$non_postgres_status" -ne 0 && "$non_postgres_status" -ne 124 ]] || {
    cat "$RUN_DIR/non-postgres.log" >&2
    fail "non-PostgreSQL listener probe did not fail promptly (exit $non_postgres_status)"
  }
  printf 'NON_POSTGRES_LISTENER_TEST=PASS\nNON_POSTGRES_EXIT_CODE=%s\n' "$non_postgres_status"
  printf 'DOCKER_DNS_USED_FOR_PROBE=NO\nSTARTUP_WAIT_SECONDS_MAX=10\nPROBE_IO_DEADLINE_SECONDS=2\n'
}

if (($# == 0)); then
  usage
fi

mode=$1
shift

case "$mode" in
  unit)
    (($# == 0)) || usage
    run_unit
    ;;
  build)
    (($# == 0)) || usage
    run_build
    ;;
  integration)
    (($# == 1)) || usage
    [[ -n "$1" ]] || usage
    run_integration "$1"
    ;;
  static)
    (($# == 1)) || usage
    printf 'NOT_IMPLEMENTED: static mode is reserved for Task 4\n' >&2
    exit 3
    ;;
  self-test)
    (($# == 0)) || usage
    printf 'NOT_IMPLEMENTED: self-test mode is reserved for Task 4\n' >&2
    exit 3
    ;;
  all)
    (($# == 0)) || usage
    printf 'NOT_IMPLEMENTED: all requires Task 4 static and self-test modes\n' >&2
    exit 3
    ;;
  *)
    printf 'unknown mode: %s\n' "$mode" >&2
    usage
    ;;
esac
