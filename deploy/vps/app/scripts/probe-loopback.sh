#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077
export LC_ALL=C

stop() {
  trap - ERR
  printf 'STOP=LOOPBACK_PROBE_FAILED check=%s\n' "$1"
  exit 1
}

on_error() {
  local status=$?
  trap - ERR
  printf 'STOP=LOOPBACK_PROBE_FAILED check=INTERNAL\n'
  exit "$status"
}

trap on_error ERR

if (( $# != 2 )); then
  stop ARGUMENTS
fi

image_ref=$1
node_ip=$2

if ! python3 -c 'import ipaddress, re, sys
image, address = sys.argv[1:]
valid_image = re.fullmatch(r"ghcr\.io/jcschoeman96/eventsales@sha256:[0-9a-f]{64}", image)
try:
    parsed = ipaddress.IPv4Address(address)
except ipaddress.AddressValueError:
    sys.exit(1)
sys.exit(0 if valid_image and str(parsed) == address else 1)' "$image_ref" "$node_ip" >/dev/null 2>&1; then
  stop INPUT
fi

if (( EUID != 0 )); then
  stop ROOT_REQUIRED
fi

for required_command in python3 docker timeout curl ip; do
  command -v "$required_command" >/dev/null 2>&1 || stop "MISSING_${required_command^^}"
done

tmp_dir=$(mktemp -d /tmp/eventsales-loopback-probe.XXXXXX 2>/dev/null) || stop TEMP_CAPTURE
chmod 700 "$tmp_dir" 2>/dev/null || stop TEMP_CAPTURE
capture_file=$tmp_dir/http.capture
trap 'rm -f "$capture_file" 2>/dev/null || true; rmdir "$tmp_dir" 2>/dev/null || true' EXIT

read -r -d '' SUMMARY_PY <<'PY' || true
import json
import sys

try:
    source = json.load(sys.stdin)
    config = source.get("Config") or {}
    host = source.get("HostConfig") or {}
    state = source.get("State") or {}
    network_settings = source.get("NetworkSettings") or {}
    networks = network_settings.get("Networks") or {}
    health = state.get("Health") or {}
    summary = {
        "id": source.get("Id"),
        "image": config.get("Image"),
        "state": state.get("Status"),
        "health": health.get("Status"),
        "restart_count": source.get("RestartCount"),
        "labels": {
            key: (config.get("Labels") or {}).get(key)
            for key in ("com.docker.compose.project", "com.docker.compose.service")
        },
        "port_bindings": host.get("PortBindings") or {},
        "network_ports": network_settings.get("Ports") or {},
        "networks": {
            name: {
                "ip": (details or {}).get("IPAddress"),
                "aliases": (details or {}).get("Aliases") or [],
            }
            for name, details in networks.items()
        },
    }
    json.dump(summary, sys.stdout, separators=(",", ":"))
except Exception:
    sys.exit(1)
PY

read -r -d '' SUMMARY_CHECK_PY <<'PY' || true
import ipaddress
import json
import sys

def active_bindings(value):
    result = []
    if not isinstance(value, dict):
        return result
    for container_port, bindings in value.items():
        if not isinstance(bindings, list):
            continue
        for binding in bindings:
            if isinstance(binding, dict):
                result.append((container_port, binding.get("HostIp"), str(binding.get("HostPort", ""))))
    return result

try:
    phase = sys.argv[1]
    image = sys.argv[2]
    node_ip = sys.argv[3]
    expected_project = sys.argv[4] if len(sys.argv) > 4 else ""
    expected_service = sys.argv[5] if len(sys.argv) > 5 else ""
    summary = json.load(sys.stdin)
    if phase == "app_identity":
        ok = (
            summary.get("labels", {}).get("com.docker.compose.project") == "eventsales-app"
            and summary.get("labels", {}).get("com.docker.compose.service") == "app"
            and summary.get("state") == "running"
            and summary.get("health") == "healthy"
            and summary.get("restart_count") == 0
            and summary.get("image") == image
        )
    elif phase == "topology":
        networks = summary.get("networks") or {}
        data = networks.get("eventsales-prod_eventsales_data") or {}
        edge = networks.get("eventsales-prod_eventsales_edge") or {}
        try:
            data_ip = str(ipaddress.IPv4Address(data.get("ip", "")))
            edge_ip = str(ipaddress.IPv4Address(edge.get("ip", "")))
            expected_ip = str(ipaddress.IPv4Address(node_ip))
        except ipaddress.AddressValueError:
            sys.exit(1)
        ok = (
            set(networks) == {"eventsales-prod_eventsales_data", "eventsales-prod_eventsales_edge"}
            and data_ip == expected_ip
            and edge_ip != expected_ip
            and "eventsales-app" in (data.get("aliases") or [])
            and "eventsales-app" not in (edge.get("aliases") or [])
        )
    elif phase == "loopback_ports":
        expected = [("4000/tcp", "127.0.0.1", "4100")]
        host = active_bindings(summary.get("port_bindings"))
        network = active_bindings(summary.get("network_ports"))
        ok = host == expected and network == expected
    elif phase == "service":
        ok = (
            summary.get("labels", {}).get("com.docker.compose.project") == expected_project
            and summary.get("labels", {}).get("com.docker.compose.service") == expected_service
            and summary.get("state") == "running"
            and summary.get("health") == "healthy"
            and summary.get("restart_count") == 0
        )
    elif phase == "d0_container":
        ok = (
            summary.get("labels", {}).get("com.docker.compose.project") == "eventsales-d0-proof"
            and summary.get("state") == "running"
            and summary.get("health") == "healthy"
            and summary.get("restart_count") == 0
        )
    else:
        ok = False
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
PY

read -r -d '' PROC_WILDCARD_PY <<'PY' || true
import ipaddress
import sys

def listeners(path, family):
    with open(path, "r", encoding="ascii") as handle:
        lines = handle.read().splitlines()[1:]
    result = []
    for line in lines:
        fields = line.split()
        if len(fields) < 4 or fields[3] != "0A":
            continue
        address_hex, port_hex = fields[1].split(":", 1)
        if int(port_hex, 16) != 4100:
            continue
        if family == 4:
            address = ipaddress.IPv4Address(bytes.fromhex(address_hex)[::-1])
        else:
            packed = b"".join(bytes.fromhex(address_hex[i:i+8])[::-1] for i in range(0, 32, 8))
            address = ipaddress.IPv6Address(packed)
        result.append(address)
    return result

try:
    addresses = listeners("/proc/net/tcp", 4) + listeners("/proc/net/tcp6", 6)
    sys.exit(1 if any(not address.is_loopback for address in addresses) else 0)
except Exception:
    sys.exit(2)
PY

read -r -d '' EXTERNAL_DENIAL_PY <<'PY' || true
import ipaddress
import socket
import sys

try:
    addresses = set()
    for line in sys.stdin.read().splitlines():
        fields = line.split()
        if "scope" not in fields or fields[fields.index("scope") + 1] != "global":
            continue
        for family in ("inet", "inet6"):
            if family not in fields:
                continue
            candidate = ipaddress.ip_interface(fields[fields.index(family) + 1]).ip
            if not candidate.is_loopback:
                addresses.add(candidate)
            break
    if not addresses or len(addresses) > 32:
        sys.exit(11)
    for address in sorted(addresses, key=lambda item: (item.version, int(item))):
        try:
            with socket.create_connection((str(address), 4100), timeout=1.5):
                sys.exit(10)
        except OSError:
            pass
    sys.exit(0)
except Exception:
    sys.exit(12)
PY

read -r -d '' TOKEN_LIST_PY <<'PY' || true
import re
import sys

lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
count, kind = int(sys.argv[1]), sys.argv[2]
pattern = r"[0-9a-f]{64}" if kind == "hex" else r"[A-Za-z0-9_.-]+"
if len(lines) != count or len(set(lines)) != count or any(not re.fullmatch(pattern, line) for line in lines):
    sys.exit(1)
print("\n".join(sorted(lines)))
PY

read -r -d '' SUMMARY_SERVICE_PY <<'PY' || true
import json
import sys

try:
    source = json.load(sys.stdin)
    config = source.get("Config") or {}
    state = source.get("State") or {}
    health = state.get("Health") or {}
    labels = config.get("Labels") or {}
    summary = {
        "id": source.get("Id"),
        "image": config.get("Image"),
        "state": state.get("Status"),
        "health": health.get("Status"),
        "restart_count": source.get("RestartCount"),
        "labels": {
            key: labels.get(key)
            for key in ("com.docker.compose.project", "com.docker.compose.service")
        },
    }
    json.dump(summary, sys.stdout, separators=(",", ":"))
except Exception:
    sys.exit(1)
PY

read_summary() {
  local container_id=$1
  timeout --signal=TERM --kill-after=1 8s docker inspect --format '{{json .}}' "$container_id" 2>/dev/null |
    python3 -c "$SUMMARY_PY" 2>/dev/null
}

read_service_summary() {
  local container_id=$1
  timeout --signal=TERM --kill-after=1 8s docker inspect --format '{{json .}}' "$container_id" 2>/dev/null |
    python3 -c "$SUMMARY_SERVICE_PY" 2>/dev/null
}

validate_summary() {
  local summary=$1
  local phase=$2
  shift 2
  python3 -c "$SUMMARY_CHECK_PY" "$phase" "$image_ref" "$node_ip" "$@" <<<"$summary" >/dev/null 2>&1
}

filtered_list() {
  local object=$1
  local project=$2
  local service=${3:-}
  case "$object" in
    containers)
      if [[ -n $service ]]; then
        timeout --signal=TERM --kill-after=1 8s docker ps --all --quiet --no-trunc \
          --filter "label=com.docker.compose.project=$project" \
          --filter "label=com.docker.compose.service=$service" 2>/dev/null
      else
        timeout --signal=TERM --kill-after=1 8s docker ps --all --quiet --no-trunc \
          --filter "label=com.docker.compose.project=$project" 2>/dev/null
      fi
      ;;
    networks)
      timeout --signal=TERM --kill-after=1 8s docker network ls --quiet --no-trunc \
        --filter "label=com.docker.compose.project=$project" 2>/dev/null
      ;;
    volumes)
      timeout --signal=TERM --kill-after=1 8s docker volume ls --quiet \
        --filter "label=com.docker.compose.project=$project" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

list_exactly() {
  local object=$1
  local project=$2
  local service=$3
  local expected=$4
  local kind=$5
  local raw
  raw=$(filtered_list "$object" "$project" "$service") || return 1
  python3 -c "$TOKEN_LIST_PY" "$expected" "$kind" <<<"$raw" 2>/dev/null
}

snapshot_data_plane() {
  local result='' service ids container_id summary
  for service in postgres pgbouncer redis; do
    ids=$(list_exactly containers eventsales-prod "$service" 1 hex) || return 1
    container_id=$ids
    summary=$(read_service_summary "$container_id") || return 1
    validate_summary "$summary" service eventsales-prod "$service" || return 1
    result+="$service=$container_id"$'\n'
  done
  printf '%s' "$result"
}

snapshot_d0() {
  local containers networks volumes result='' container_id summary
  containers=$(list_exactly containers eventsales-d0-proof '' 3 hex) || return 2
  networks=$(list_exactly networks eventsales-d0-proof '' 2 hex) || return 2
  volumes=$(list_exactly volumes eventsales-d0-proof '' 1 name) || return 2
  while IFS= read -r container_id; do
    [[ -n $container_id ]] || continue
    summary=$(read_service_summary "$container_id") || return 1
    validate_summary "$summary" d0_container || return 1
  done <<<"$containers"
  result="containers=$containers"$'\n'"networks=$networks"$'\n'"volumes=$volumes"
  printf '%s' "$result"
}

verify_app_continuity() {
  local ids summary
  ids=$(list_exactly containers eventsales-app app 1 hex) || return 1
  [[ $ids == "$app_id" ]] || return 1
  summary=$(read_summary "$app_id") || return 1
  validate_summary "$summary" app_identity || return 1
  validate_summary "$summary" topology || return 1
}

probe_http() {
  local path=$1
  local expected_body=$2
  local check_id=$3
  local status
  : >"$capture_file"
  chmod 600 "$capture_file" 2>/dev/null || stop TEMP_CAPTURE
  status=$(timeout --signal=TERM --kill-after=1 8s curl --noproxy '*' --silent --show-error \
    --connect-timeout 2 --max-time 5 --output "$capture_file" --write-out '%{http_code}' \
    --header 'Host: localhost' --header 'X-Forwarded-Proto: https' \
    "http://127.0.0.1:4100/$path" 2>/dev/null) || stop "$check_id"
  [[ $status == 200 ]] || stop "$check_id"
  python3 -c 'import sys
try:
    body = open(sys.argv[1], "rb").read()
except Exception:
    sys.exit(1)
sys.exit(0 if body == sys.argv[2].encode("ascii") else 1)' "$capture_file" "$expected_body" >/dev/null 2>&1 || stop "$check_id"
}

app_ids=$(list_exactly containers eventsales-app app 1 hex) || stop APP_CONTAINER_COUNT
app_id=$app_ids
app_summary=$(read_summary "$app_id") || stop APP_INSPECT
validate_summary "$app_summary" app_identity || stop APP_CONTINUITY
validate_summary "$app_summary" topology || stop NETWORK_TOPOLOGY
printf 'LOOPBACK_APP_CONTINUITY=PASS\n'
validate_summary "$app_summary" loopback_ports || stop EXACT_BINDING
printf 'LOOPBACK_EXACT_BINDING=PASS\n'

if python3 -c "$PROC_WILDCARD_PY" >/dev/null 2>&1; then
  proc_status=0
else
  proc_status=$?
fi
case "$proc_status" in
  0) ;;
  1) stop WILDCARD_LISTENER ;;
  *) stop HOST_SOCKET_INSPECTION ;;
esac
printf 'LOOPBACK_NO_WILDCARD=PASS\n'

data_plane_before=$(snapshot_data_plane) || stop DATA_PLANE_INITIAL
d0_before=$(snapshot_d0) || {
  status=$?
  if (( status == 2 )); then
    trap - ERR
    printf 'STOP=D0_IDENTITY_NOT_PROVABLE\n'
    exit 1
  fi
  stop D0_INITIAL
}

ipv4_addresses=$(timeout --signal=TERM --kill-after=1 6s ip -o -4 addr show scope global 2>/dev/null) || stop EXTERNAL_INTERFACE_ENUMERATION
ipv6_addresses=$(timeout --signal=TERM --kill-after=1 6s ip -o -6 addr show scope global 2>/dev/null) || stop EXTERNAL_INTERFACE_ENUMERATION
if printf '%s\n%s\n' "$ipv4_addresses" "$ipv6_addresses" |
  timeout --signal=TERM --kill-after=1 45s python3 -c "$EXTERNAL_DENIAL_PY" >/dev/null 2>&1; then
  external_status=0
else
  external_status=$?
fi
case "$external_status" in
  0) ;;
  10) stop EXTERNAL_INTERFACE_ACCEPTED_4100 ;;
  *) stop EXTERNAL_INTERFACE_DENIAL ;;
esac
printf 'LOOPBACK_EXTERNAL_DENIAL=PASS\n'

probe_http health ok LOOPBACK_HEALTH
printf 'LOOPBACK_HEALTH=PASS\n'
probe_http ready ready LOOPBACK_READY
printf 'LOOPBACK_READY=PASS\n'

verify_app_continuity || stop APP_CONTINUITY
data_plane_after=$(snapshot_data_plane) || stop DATA_PLANE_STABILITY
[[ $data_plane_after == "$data_plane_before" ]] || stop DATA_PLANE_STABILITY
printf 'LOOPBACK_DATA_PLANE_STABILITY=PASS\n'
d0_after=$(snapshot_d0) || stop D0_STABILITY
[[ $d0_after == "$d0_before" ]] || stop D0_STABILITY
printf 'LOOPBACK_D0_STABILITY=PASS\n'
printf 'LOOPBACK_PROBE=PASS\n'
