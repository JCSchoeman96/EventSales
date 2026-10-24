#!/usr/bin/env bash

set -Eeuo pipefail
set +x
umask 077
export LC_ALL=C

stop() {
  trap - ERR
  printf 'STOP=PRIVATE_PROBE_FAILED check=%s\n' "$1"
  exit 1
}

on_error() {
  local status=$?
  trap - ERR
  printf 'STOP=PRIVATE_PROBE_FAILED check=INTERNAL\n'
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

tmp_dir=$(mktemp -d /tmp/eventsales-private-probe.XXXXXX 2>/dev/null) || stop TEMP_CAPTURE
chmod 700 "$tmp_dir" 2>/dev/null || stop TEMP_CAPTURE
capture_file=$tmp_dir/rpc.capture
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
    env_names = []
    for entry in config.get("Env") or []:
        if isinstance(entry, str) and "=" in entry:
            env_names.append(entry.split("=", 1)[0])
        else:
            env_names.append("<malformed>")
    health = state.get("Health") or {}
    summary = {
        "id": source.get("Id"),
        "image": config.get("Image"),
        "user": config.get("User"),
        "readonly_rootfs": host.get("ReadonlyRootfs"),
        "init": host.get("Init"),
        "restart_policy": (host.get("RestartPolicy") or {}).get("Name"),
        "cap_drop": host.get("CapDrop") or [],
        "cap_add": host.get("CapAdd") or [],
        "privileged": host.get("Privileged"),
        "devices": host.get("Devices") or [],
        "device_requests": host.get("DeviceRequests") or [],
        "pid_mode": host.get("PidMode") or "",
        "ipc_mode": host.get("IpcMode") or "",
        "security_opt": host.get("SecurityOpt") or [],
        "nano_cpus": host.get("NanoCpus") or 0,
        "cpu_quota": host.get("CpuQuota") or 0,
        "cpu_period": host.get("CpuPeriod") or 0,
        "memory": host.get("Memory") or 0,
        "pids_limit": host.get("PidsLimit"),
        "tmpfs": host.get("Tmpfs") or {},
        "port_bindings": host.get("PortBindings") or {},
        "network_ports": network_settings.get("Ports") or {},
        "mounts": [
            {"destination": mount.get("Destination"), "type": mount.get("Type"), "rw": mount.get("RW")}
            for mount in source.get("Mounts") or []
        ],
        "networks": {
            name: {
                "ip": (details or {}).get("IPAddress"),
                "aliases": (details or {}).get("Aliases") or [],
            }
            for name, details in networks.items()
        },
        "state": state.get("Status"),
        "health": health.get("Status"),
        "restart_count": source.get("RestartCount"),
        "labels": {
            key: (config.get("Labels") or {}).get(key)
            for key in ("com.docker.compose.project", "com.docker.compose.service")
        },
        "env_names": env_names,
    }
    json.dump(summary, sys.stdout, separators=(",", ":"))
except Exception:
    sys.exit(1)
PY

read -r -d '' SUMMARY_CHECK_PY <<'PY' || true
import ipaddress
import json
import re
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

def exact_dns_names(summary):
    names = set(summary.get("networks", {}))
    return names == {"eventsales-prod_eventsales_data", "eventsales-prod_eventsales_edge"}

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
    elif phase == "security":
        options = summary.get("security_opt") or []
        ok = (
            summary.get("user") == "eventsales"
            and summary.get("readonly_rootfs") is True
            and summary.get("init") is True
            and summary.get("restart_policy") == "unless-stopped"
            and "ALL" in (summary.get("cap_drop") or [])
            and "no-new-privileges:true" in options
        )
    elif phase == "capabilities":
        ok = "ALL" in (summary.get("cap_drop") or []) and not (summary.get("cap_add") or [])
    elif phase == "privileged":
        ok = summary.get("privileged") is False
    elif phase == "namespace_device":
        ok = (
            summary.get("pid_mode") != "host"
            and summary.get("ipc_mode") != "host"
            and not (summary.get("devices") or [])
            and not (summary.get("device_requests") or [])
        )
    elif phase == "resources":
        nano_cpus = summary.get("nano_cpus") or 0
        quota = summary.get("cpu_quota") or 0
        period = summary.get("cpu_period") or 0
        cpu_ok = (
            nano_cpus == 4_000_000_000 and (quota == 0 or (period > 0 and quota == 4 * period))
        ) or (nano_cpus == 0 and period > 0 and quota == 4 * period)
        memory_ok = summary.get("memory") == 2_147_483_648
        pids_ok = summary.get("pids_limit") == 512
        tmpfs = summary.get("tmpfs") or {}
        tmpfs_ok = False
        if set(tmpfs) == {"/tmp"} and isinstance(tmpfs.get("/tmp"), str):
            tokens = tmpfs["/tmp"].split(",")
            normalized = set()
            for token in tokens:
                if token.lower() in {"rw", "noexec", "nosuid", "nodev"}:
                    normalized.add(token.lower())
                elif token.lower().startswith("size="):
                    size = token.split("=", 1)[1].lower()
                    normalized.add("size=64m" if size in {"64m", "64mb", "64mi", "67108864"} else "size=invalid")
                elif token.lower().startswith("mode="):
                    normalized.add("mode=" + token.split("=", 1)[1])
                else:
                    normalized.add("invalid=" + token)
            tmpfs_ok = len(tokens) == 6 and normalized == {"rw", "noexec", "nosuid", "nodev", "size=64m", "mode=1777"}
        mounts = summary.get("mounts") or []
        mounts_ok = mounts == [{"destination": "/tmp", "type": "tmpfs", "rw": True}]
        ok = cpu_ok and memory_ok and pids_ok and tmpfs_ok and mounts_ok
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
        data_aliases = data.get("aliases") or []
        edge_aliases = edge.get("aliases") or []
        ok = (
            exact_dns_names(summary)
            and data_ip == expected_ip
            and edge_ip != expected_ip
            and "eventsales-app" in data_aliases
            and "eventsales-app" not in edge_aliases
        )
        if ok:
            print(edge_ip)
    elif phase == "private_ports":
        ok = not active_bindings(summary.get("port_bindings")) and not active_bindings(summary.get("network_ports"))
    elif phase == "loopback_ports":
        expected = [("4000/tcp", "127.0.0.1", "4100")]
        host = active_bindings(summary.get("port_bindings"))
        network = active_bindings(summary.get("network_ports"))
        ok = host == expected and network == expected
    elif phase == "environment":
        forbidden = {
            "DIRECT_DATABASE_URL",
            "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL",
            "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD",
            "EVENTSALES_BOOTSTRAP_ADMIN_NAME",
            "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD",
            "EVENTSALES_BOOTSTRAP_SOURCE_NAME",
            "EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL",
            "POSTGRES_PASSWORD",
            "POSTGRES_PASSWORD_FILE",
            "PGPASSWORD",
            "PGPASSFILE",
            "EVENTSALES_SECRET_DIR",
            "EVENTSALES_MIGRATOR_PASSWORD",
            "EVENTSALES_BACKUP_PASSWORD",
            "POSTGRES_BOOTSTRAP_PASSWORD",
        }
        ok = not (forbidden & set(summary.get("env_names") or []))
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

read_summary() {
  local container_id=$1
  timeout --signal=TERM --kill-after=1 8s docker inspect --format '{{json .}}' "$container_id" 2>/dev/null |
    python3 -c "$SUMMARY_PY" 2>/dev/null
}

validate_summary() {
  local summary=$1
  local phase=$2
  shift 2
  python3 -c "$SUMMARY_CHECK_PY" "$phase" "$image_ref" "$node_ip" "$@" <<<"$summary" >/dev/null 2>&1
}

validate_tokens() {
  local raw=$1
  local count=$2
  local kind=$3
  python3 -c 'import re, sys
lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
count, kind = int(sys.argv[1]), sys.argv[2]
pattern = r"[0-9a-f]{64}" if kind == "hex" else r"[A-Za-z0-9_.-]+"
if len(lines) != count or len(set(lines)) != count or any(not re.fullmatch(pattern, line) for line in lines):
    sys.exit(1)
print("\n".join(sorted(lines)))' "$count" "$kind" <<<"$raw" 2>/dev/null
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
  validate_tokens "$raw" "$expected" "$kind"
}

snapshot_data_plane() {
  local result='' all_ids
  local service ids container_id summary
  all_ids=$(list_exactly containers eventsales-prod '' 3 hex) || return 1
  for service in postgres pgbouncer redis; do
    ids=$(list_exactly containers eventsales-prod "$service" 1 hex) || return 1
    container_id=$ids
    summary=$(read_summary "$container_id") || return 1
    validate_summary "$summary" service eventsales-prod "$service" || return 1
    result+="$service=$container_id"$'\n'
  done
  python3 -c 'import sys
expected = sorted(line for line in sys.argv[1].splitlines() if line)
actual = sorted(line.split("=", 1)[1] for line in sys.argv[2].splitlines() if line)
sys.exit(0 if expected == actual else 1)' "$all_ids" "$result" >/dev/null 2>&1 || return 1
  printf '%s' "$result"
}

snapshot_d0() {
  local containers networks volumes result='' container_id summary
  containers=$(list_exactly containers eventsales-d0-proof '' 3 hex) || return 2
  networks=$(list_exactly networks eventsales-d0-proof '' 2 hex) || return 2
  volumes=$(list_exactly volumes eventsales-d0-proof '' 1 name) || return 2
  while IFS= read -r container_id; do
    [[ -n $container_id ]] || continue
    summary=$(read_summary "$container_id") || return 1
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
}

check_smoke_output() {
  python3 -c 'import sys
expected = [
    "private runtime smoke: application passed",
    "private runtime smoke: migrations passed",
    "private runtime smoke: database identity passed",
    "private runtime smoke: prepared queries passed",
    "private runtime smoke: Ash read passed",
    "private runtime smoke: Oban success and retry passed",
    "private runtime smoke: Oban notifier passed",
    "private runtime smoke: Redis rate limiter passed",
    "private runtime smoke: hot-state Redis snapshots passed",
    "private runtime smoke: database readiness passed",
    "private runtime smoke: webhook buffer disabled passed",
    "private runtime smoke: secret-safe evidence passed",
    "private runtime smoke: complete",
]
lines = open(sys.argv[1], "r", encoding="utf-8", errors="strict").read().splitlines()
sys.exit(0 if all(lines.count(label) == 1 for label in expected) else 1)' "$capture_file" >/dev/null 2>&1
}

check_rpc_proofs() {
  python3 -c 'import ipaddress, re, sys

def marker(lines, key):
    found = [line[len(key):] for line in lines if line.startswith(key)]
    if len(found) != 1:
        raise ValueError
    return found[0]

def parse_table(lines, start, end, family):
    try:
        begin = lines.index(start) + 1
        finish = lines.index(end, begin)
    except ValueError:
        raise ValueError
    sockets = []
    for line in lines[begin:finish]:
        fields = line.split()
        if len(fields) < 4 or fields[3] != "0A":
            continue
        local = fields[1]
        address_hex, port_hex = local.split(":", 1)
        if family == 4:
            packed = bytes.fromhex(address_hex)[::-1]
            address = ipaddress.IPv4Address(packed)
        else:
            packed = b"".join(bytes.fromhex(address_hex[i:i+8])[::-1] for i in range(0, 32, 8))
            address = ipaddress.IPv6Address(packed)
        sockets.append((address, int(port_hex, 16)))
    return sockets

try:
    expected_ip = str(ipaddress.IPv4Address(sys.argv[1]))
    lines = open(sys.argv[2], "r", encoding="utf-8", errors="strict").read().splitlines()
    node_alive = marker(lines, "NODE_ALIVE=")
    node_self = marker(lines, "NODE_SELF=")
    pubsub_alive = marker(lines, "PUBSUB_ALIVE=")
    dns = marker(lines, "DNS_IPV4=")
    epmd_status = marker(lines, "EPMD_STATUS=")
    dist_port_text = marker(lines, "BEAM_DIST_PORT=")
    if node_alive != "true" or node_self != "event_sales@" + expected_ip or pubsub_alive != "true":
        sys.exit(1)
    if dns != expected_ip or epmd_status != "0" or not re.fullmatch(r"[0-9]{1,5}", dist_port_text):
        sys.exit(1)
    dist_port = int(dist_port_text)
    if not 1 <= dist_port <= 65535 or dist_port == 4369:
        sys.exit(1)
    sockets = parse_table(lines, "PROC_TCP4_BEGIN", "PROC_TCP4_END", 4)
    sockets += parse_table(lines, "PROC_TCP6_BEGIN", "PROC_TCP6_END", 6)
    loopback = lambda address: address.is_loopback
    epmd = [address for address, port in sockets if port == 4369]
    beam = [address for address, port in sockets if port == dist_port]
    if not epmd or not beam or ipaddress.IPv4Address(expected_ip) not in epmd or ipaddress.IPv4Address(expected_ip) not in beam:
        sys.exit(1)
    if any(address != ipaddress.IPv4Address(expected_ip) and not loopback(address) for address in epmd + beam):
        sys.exit(1)
    sys.exit(0)
except Exception:
    sys.exit(1)' "$node_ip" "$capture_file" >/dev/null 2>&1
}

probe_http() {
  local url=$1
  local expected_body=$2
  local check_id=$3
  local status
  : >"$capture_file"
  chmod 600 "$capture_file" 2>/dev/null || stop TEMP_CAPTURE
  status=$(timeout --signal=TERM --kill-after=1 8s curl --noproxy '*' --silent --show-error \
    --connect-timeout 2 --max-time 5 --output "$capture_file" --write-out '%{http_code}' \
    --header 'Host: localhost' --header 'X-Forwarded-Proto: https' "$url" 2>/dev/null) || stop "$check_id"
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
validate_summary "$app_summary" app_identity || stop APP_IDENTITY
printf 'PRIVATE_APP_IDENTITY=PASS\n'
validate_summary "$app_summary" security || stop SECURITY_ENVELOPE
printf 'PRIVATE_SECURITY_ENVELOPE=PASS\n'
validate_summary "$app_summary" capabilities || stop CAPABILITIES
printf 'PRIVATE_CAPABILITIES=PASS\n'
validate_summary "$app_summary" privileged || stop PRIVILEGED
printf 'PRIVATE_PRIVILEGED=PASS\n'
validate_summary "$app_summary" namespace_device || stop NAMESPACE_DEVICE
printf 'PRIVATE_NAMESPACE_DEVICE=PASS\n'
validate_summary "$app_summary" resources || stop RESOURCE_ENVELOPE
printf 'PRIVATE_RESOURCE_ENVELOPE=PASS\n'
printf 'PRIVATE_EXACT_MOUNTS=PASS\n'
edge_ip=$(python3 -c "$SUMMARY_CHECK_PY" topology "$image_ref" "$node_ip" <<<"$app_summary" 2>/dev/null) || stop NETWORK_TOPOLOGY
printf 'PRIVATE_NETWORK_TOPOLOGY=PASS\n'
validate_summary "$app_summary" private_ports || stop HOST_PORTS
printf 'PRIVATE_NO_HOST_PORTS=PASS\n'
validate_summary "$app_summary" environment || stop ENVIRONMENT_BOUNDARY
printf 'PRIVATE_ENVIRONMENT_BOUNDARY=PASS\n'

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

release_expression='IO.puts("NODE_ALIVE=" <> to_string(Node.alive?()))
IO.puts("NODE_SELF=" <> Atom.to_string(Node.self()))
IO.puts("PUBSUB_ALIVE=" <> to_string(Process.whereis(EventSales.PubSub) != nil))
dns = case :inet.getaddrs(~c"eventsales-app", :inet) do
  {:ok, addresses} -> addresses |> Enum.map(&:inet.ntoa/1) |> Enum.map(&List.to_string/1) |> Enum.sort() |> Enum.join(",")
  _ -> "lookup_failed"
end
IO.puts("DNS_IPV4=" <> dns)
epmd_path = Path.join([:code.root_dir(), "bin", "epmd"])
epmd = if File.exists?(epmd_path), do: epmd_path, else: System.find_executable("epmd")
{epmd_output, epmd_status} = if epmd, do: System.cmd(epmd, ["-names"], stderr_to_stdout: true), else: {"", 127}
dist_port = case Regex.run(~r/name event_sales at port ([0-9]+)/, epmd_output) do
  [_, port] -> port
  _ -> "missing"
end
IO.puts("EPMD_STATUS=" <> to_string(epmd_status))
IO.puts("BEAM_DIST_PORT=" <> dist_port)
{:ok, tcp4} = File.read("/proc/net/tcp")
{:ok, tcp6} = File.read("/proc/net/tcp6")
IO.puts("PROC_TCP4_BEGIN")
IO.write(tcp4)
IO.puts("PROC_TCP4_END")
IO.puts("PROC_TCP6_BEGIN")
IO.write(tcp6)
IO.puts("PROC_TCP6_END")'
: >"$capture_file"
chmod 600 "$capture_file" 2>/dev/null || stop TEMP_CAPTURE
timeout --signal=TERM --kill-after=1 25s docker exec "$app_id" bin/event_sales rpc "$release_expression" \
  >"$capture_file" 2>/dev/null || stop RELEASE_RPC
python3 -c 'import sys
lines = open(sys.argv[1], "r", encoding="utf-8", errors="strict").read().splitlines()
keys = ("NODE_ALIVE=", "NODE_SELF=", "PUBSUB_ALIVE=", "DNS_IPV4=", "EPMD_STATUS=", "BEAM_DIST_PORT=", "PROC_TCP4_BEGIN", "PROC_TCP4_END", "PROC_TCP6_BEGIN", "PROC_TCP6_END")
sys.exit(0 if all(sum(line == key or line.startswith(key) for line in lines) == 1 for key in keys) else 1)' "$capture_file" >/dev/null 2>&1 || stop RELEASE_RPC_OUTPUT
printf 'PRIVATE_RELEASE_RPC=PASS\n'
python3 -c 'import sys
lines = open(sys.argv[1], "r", encoding="utf-8", errors="strict").read().splitlines()
def one(key):
    found = [line[len(key):] for line in lines if line.startswith(key)]
    return found[0] if len(found) == 1 else ""
sys.exit(0 if one("NODE_ALIVE=") == "true" and one("NODE_SELF=") == "event_sales@" + sys.argv[2] else 1)' \
  "$capture_file" "$node_ip" >/dev/null 2>&1 || stop NODE_IDENTITY
printf 'PRIVATE_NODE_IDENTITY=PASS\n'
python3 -c 'import sys
lines = open(sys.argv[1], "r", encoding="utf-8", errors="strict").read().splitlines()
found = [line[len("PUBSUB_ALIVE="):] for line in lines if line.startswith("PUBSUB_ALIVE=")]
sys.exit(0 if found == ["true"] else 1)' "$capture_file" >/dev/null 2>&1 || stop PUBSUB
printf 'PRIVATE_PUBSUB=PASS\n'
python3 -c 'import ipaddress, sys
lines = open(sys.argv[1], "r", encoding="utf-8", errors="strict").read().splitlines()
found = [line[len("DNS_IPV4="):] for line in lines if line.startswith("DNS_IPV4=")]
sys.exit(0 if found == [str(ipaddress.IPv4Address(sys.argv[2]))] else 1)' \
  "$capture_file" "$node_ip" >/dev/null 2>&1 || stop CLUSTER_DNS
printf 'PRIVATE_CLUSTER_DNS=PASS\n'
check_rpc_proofs || stop BEAM_EPMD_BIND
printf 'PRIVATE_BEAM_BIND=PASS\n'
printf 'PRIVATE_EPMD_BIND=PASS\n'

: >"$capture_file"
chmod 600 "$capture_file" 2>/dev/null || stop TEMP_CAPTURE
timeout --signal=TERM --kill-after=1 65s docker exec "$app_id" bin/event_sales rpc \
  'EventSales.Maintenance.PrivateRuntimeSmoke.run!()' >"$capture_file" 2>/dev/null || stop RUNTIME_SMOKE_RPC
check_smoke_output || stop RUNTIME_SMOKE_OUTPUT
printf 'PRIVATE_RUNTIME_SMOKE=PASS\n'

probe_http "http://$edge_ip:4000/health" ok PRIVATE_HTTP_HEALTH
printf 'PRIVATE_HTTP_HEALTH=PASS\n'
probe_http "http://$edge_ip:4000/ready" ready PRIVATE_HTTP_READY
printf 'PRIVATE_HTTP_READY=PASS\n'

verify_app_continuity || stop APP_CONTINUITY
data_plane_after=$(snapshot_data_plane) || stop DATA_PLANE_STABILITY
[[ $data_plane_after == "$data_plane_before" ]] || stop DATA_PLANE_STABILITY
printf 'PRIVATE_DATA_PLANE_STABILITY=PASS\n'
d0_after=$(snapshot_d0) || stop D0_STABILITY
[[ $d0_after == "$d0_before" ]] || stop D0_STABILITY
printf 'PRIVATE_D0_STABILITY=PASS\n'
printf 'PRIVATE_PROBE=PASS\n'
