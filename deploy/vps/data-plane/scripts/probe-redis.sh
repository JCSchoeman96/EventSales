#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
LC_ALL=C
export LC_ALL
unset PGPASSWORD PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGSERVICE PGSERVICEFILE
unset REDISCLI_AUTH COMPOSE_PROJECT_NAME COMPOSE_PROFILES

readonly EXPECTED_PROJECT=eventsales-prod
readonly EXPECTED_COMPOSE_FILE=deploy/vps/data-plane/compose.yaml
readonly DOCKER_TIMEOUT=20s
readonly CLIENT_TIMEOUT=12s
readonly RATE_LIMIT_TTL_MS=60000
readonly HOT_STATE_TTL_MS=3600000
readonly SCAN_COUNT=64
readonly SCAN_MAX_ITERATIONS=16

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DATA_PLANE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
REPOSITORY_ROOT=$(cd -- "$DATA_PLANE_DIR/../../.." && pwd -P)
COMPOSE_PROJECT=${COMPOSE_PROJECT:-$EXPECTED_PROJECT}
COMPOSE_FILE=${COMPOSE_FILE:-$EXPECTED_COMPOSE_FILE}
export COMPOSE_PROJECT COMPOSE_FILE

secret_dir=
runtime_secret=
stats_secret=
evidence_file=
failure_reported=false
temporary_outputs=()
created_output_path=
created_error_path=
runtime_auth_proven=false
stats_auth_proven=false
default_auth_proven=false

record() {
  if [[ -n "$evidence_file" ]]; then
    printf '%s\n' "$1" >>"$evidence_file"
  fi
}

report_preflight_failure() {
  local check_id=$1
  failure_reported=true
  record 'REDIS_PREFLIGHT=FAIL'
  record "FAILED_CHECK=$check_id"
  printf 'STOP=REDIS_PROBE_PREFLIGHT_FAILED check=%s\n' "$check_id" >&2
  if [[ -n "$evidence_file" ]]; then
    printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
  fi
  exit 1
}

report_failure() {
  local check_id=$1
  failure_reported=true
  record 'REDIS_STATE=FAILED_PRESERVED'
  record 'REDIS_PROBE=FAIL'
  record "FAILED_CHECK=$check_id"
  printf 'STOP=REDIS_PROBE_FAILED check=%s\n' "$check_id" >&2
  printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
  exit 1
}

on_exit() {
  local status=$?
  trap - EXIT
  if ((status != 0)) && [[ "$failure_reported" != true ]]; then
    failure_reported=true
    record 'REDIS_STATE=FAILED_PRESERVED'
    record 'REDIS_PROBE=FAIL'
    record 'FAILED_CHECK=UNEXPECTED_SHELL_FAILURE'
    printf 'STOP=REDIS_PROBE_FAILED check=UNEXPECTED_SHELL_FAILURE\n' >&2
    if [[ -n "$evidence_file" ]]; then
      printf 'EVIDENCE_FILE=%s\n' "$evidence_file" >&2
    fi
  fi
  local output_file
  for output_file in "${temporary_outputs[@]}"; do
    [[ -n "$output_file" ]] && rm -f -- "$output_file" 2>/dev/null || true
  done
}

trap on_exit EXIT
trap 'report_failure INTERRUPTED' HUP INT TERM

if (($# != 1)); then
  report_preflight_failure ARGUMENT_COUNT
fi
if ((EUID != 0)); then
  report_preflight_failure ROOT_REQUIRED
fi
if [[ "$COMPOSE_PROJECT" != "$EXPECTED_PROJECT" ]]; then
  report_preflight_failure COMPOSE_PROJECT_INVALID
fi
if [[ "$COMPOSE_FILE" != "$EXPECTED_COMPOSE_FILE" ]]; then
  report_preflight_failure COMPOSE_FILE_INVALID
fi

secret_dir=$1
if [[ "$secret_dir" != /* || "$secret_dir" == / || "$secret_dir" == */ || "$secret_dir" == *//* ]]; then
  report_preflight_failure SECRET_DIRECTORY_PATH_INVALID
fi
relative_path=${secret_dir#/}
IFS='/' read -r -a path_parts <<<"$relative_path"
current_path=
for part in "${path_parts[@]}"; do
  if [[ -z "$part" || "$part" == . || "$part" == .. ]]; then
    report_preflight_failure SECRET_DIRECTORY_PATH_INVALID
  fi
  current_path="${current_path%/}/$part"
  if [[ -L "$current_path" ]]; then
    report_preflight_failure SECRET_DIRECTORY_SYMLINK
  fi
done
if [[ ! -d "$secret_dir" ]]; then
  report_preflight_failure SECRET_DIRECTORY_NOT_DIRECTORY
fi
secret_metadata=$(stat -c '%u:%g:%a' -- "$secret_dir" 2>/dev/null) || report_preflight_failure SECRET_DIRECTORY_METADATA_UNAVAILABLE
if [[ "$secret_metadata" != 0:0:700 ]]; then
  report_preflight_failure SECRET_DIRECTORY_METADATA_MISMATCH
fi
resolved_secret_dir=$(cd -- "$secret_dir" && pwd -P 2>/dev/null) || report_preflight_failure SECRET_DIRECTORY_UNAVAILABLE
if [[ "$resolved_secret_dir" != "$secret_dir" ]]; then
  report_preflight_failure SECRET_DIRECTORY_PATH_NOT_CANONICAL
fi

validated_secret_path=
validate_password_file() {
  local file_name=$1
  local path="$secret_dir/$file_name"
  local metadata size

  if [[ -L "$path" ]]; then
    report_preflight_failure "SECRET_FILE_SYMLINK_$file_name"
  fi
  if [[ ! -f "$path" ]]; then
    report_preflight_failure "SECRET_FILE_NOT_REGULAR_$file_name"
  fi
  metadata=$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null) || report_preflight_failure "SECRET_FILE_METADATA_UNAVAILABLE_$file_name"
  if [[ "$metadata" != 0:0:400 ]]; then
    report_preflight_failure "SECRET_FILE_METADATA_MISMATCH_$file_name"
  fi
  size=$(stat -c '%s' -- "$path" 2>/dev/null) || report_preflight_failure "SECRET_FILE_SIZE_UNAVAILABLE_$file_name"
  if [[ "$size" != 64 ]] || ! grep -Eq '^[0-9a-f]{64}$' "$path" 2>/dev/null; then
    report_preflight_failure "SECRET_FILE_FORMAT_INVALID_$file_name"
  fi
  validated_secret_path=$path
}

validate_password_file redis_runtime_password
runtime_secret=$validated_secret_path
validate_password_file redis_stats_password
stats_secret=$validated_secret_path
export EVENTSALES_SECRET_DIR="$secret_dir"
cd -- "$REPOSITORY_ROOT"

if [[ -L "$secret_dir/redis-users.acl" || ! -f "$secret_dir/redis-users.acl" ]]; then
  report_preflight_failure REDIS_ACL_FILE_UNAVAILABLE
fi
if ! python3 -I - "$secret_dir/redis-users.acl" >/dev/null 2>&1 <<'PY'
import re
import sys
from pathlib import Path

try:
    lines = [
        line.split()
        for line in Path(sys.argv[1]).read_text(encoding="ascii").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
except (OSError, UnicodeError):
    raise SystemExit(1)

runtime_commands = [
    "+ping", "+get", "+set", "+del", "+exists", "+expire", "+pexpire",
    "+ttl", "+pttl", "+multi", "+exec", "+discard", "+zadd", "+zrem",
    "+zcard", "+zremrangebyscore", "+scan",
]
default = ["user", "default", "on", "nopass", "resetkeys", "resetchannels", "-@all", "+ping"]
runtime_prefix = ["user", "eventsales_runtime", "on"]
runtime_rules = [
    "resetkeys", "resetchannels", "-@all", "~eventsales:prod:*", *runtime_commands,
]
stats_prefix = ["user", "eventsales_stats", "on"]
stats_rules = ["resetkeys", "resetchannels", "-@all", "+ping", "+info", "+config|get"]

if len(lines) != 3 or lines[0] != default:
    raise SystemExit(1)
runtime, stats = lines[1], lines[2]
if len(runtime) != len(runtime_prefix) + 1 + len(runtime_rules):
    raise SystemExit(1)
if runtime[:len(runtime_prefix)] != runtime_prefix:
    raise SystemExit(1)
if re.fullmatch(r"#[0-9a-f]{64}", runtime[len(runtime_prefix)]) is None:
    raise SystemExit(1)
if runtime[len(runtime_prefix) + 1:] != runtime_rules:
    raise SystemExit(1)
if len(stats) != len(stats_prefix) + 1 + len(stats_rules):
    raise SystemExit(1)
if stats[:len(stats_prefix)] != stats_prefix:
    raise SystemExit(1)
stats_hash = stats[len(stats_prefix)]
if re.fullmatch(r"#[0-9a-f]{64}", stats_hash) is None:
    raise SystemExit(1)
if stats_hash == runtime[len(runtime_prefix)]:
    raise SystemExit(1)
if stats[len(stats_prefix) + 1:] != stats_rules:
    raise SystemExit(1)
PY
then
  report_preflight_failure REDIS_ACL_STRUCTURE_MISMATCH
fi

compose() {
  timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" "$@"
}

if ! command -v docker >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  report_preflight_failure REQUIRED_TOOL_UNAVAILABLE
fi
if ! compose config -q >/dev/null 2>&1; then
  report_preflight_failure COMPOSE_CONFIG_FAILED
fi
if ! model=$(compose config --format json 2>/dev/null); then
  report_preflight_failure COMPOSE_MODEL_UNAVAILABLE
fi
if ! printf '%s' "$model" | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("services",{}).get("redis",{}); raise SystemExit(1 if s.get("ports") else 0)' >/dev/null 2>&1; then
  report_preflight_failure REDIS_HOST_PORT_CONFIGURED
fi
unset model

running_services=$(compose ps --status running --services redis 2>/dev/null) || report_preflight_failure COMPOSE_STATUS_FAILED
running_services=$(printf '%s\n' "$running_services" | sed '/^[[:space:]]*$/d' | sort)
if [[ "$running_services" != redis ]]; then
  report_preflight_failure REDIS_SERVICE_NOT_RUNNING
fi

container_id=$(compose ps -q redis 2>/dev/null) || report_preflight_failure REDIS_CONTAINER_LOOKUP_FAILED
if [[ ! "$container_id" =~ ^[[:xdigit:]]{12,64}$ ]]; then
  report_preflight_failure REDIS_CONTAINER_LOOKUP_FAILED
fi
ports_json=$(timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" docker inspect --format '{{json .NetworkSettings.Ports}}' "$container_id" 2>/dev/null) || report_preflight_failure REDIS_PORT_INSPECT_FAILED
if ! python3 -c 'import json,sys; ports=json.loads(sys.argv[1]); raise SystemExit(1 if any(bool(v) for v in ports.values()) else 0)' "$ports_json" >/dev/null 2>&1; then
  report_preflight_failure REDIS_HOST_PORT_PUBLISHED
fi
compose exec -T redis sh -c 'command -v redis-cli >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1' >/dev/null 2>&1 || report_preflight_failure REDIS_CLIENT_UNAVAILABLE

evidence_file=$(mktemp -- "$secret_dir/eventsales-r44-redis.XXXXXXXX") || report_preflight_failure EVIDENCE_FILE_CREATE_FAILED
chmod 600 -- "$evidence_file" || report_preflight_failure EVIDENCE_FILE_PERMISSION_FAILED
record 'REDIS_STATE=PRISTINE'
record 'REDIS_ACL_STRUCTURE=PASS'
printf 'REDIS_ACL_STRUCTURE=PASS\n'

create_output_file() {
  created_output_path=$(mktemp -- "$secret_dir/.eventsales-r44-redis-output.XXXXXXXX") || report_preflight_failure CLIENT_OUTPUT_CREATE_FAILED
  chmod 600 -- "$created_output_path" || report_preflight_failure CLIENT_OUTPUT_PERMISSION_FAILED
  temporary_outputs+=("$created_output_path")
}

create_error_file() {
  created_error_path=$(mktemp -- "$secret_dir/.eventsales-r44-redis-stderr.XXXXXXXX") || report_preflight_failure CLIENT_STDERR_CREATE_FAILED
  chmod 600 -- "$created_error_path" || report_preflight_failure CLIENT_STDERR_PERMISSION_FAILED
  temporary_outputs+=("$created_error_path")
}

auth_client_with_stderr() {
  local password_file=$1 username=$2 output_file=$3 error_file=$4 raw_error_file status
  shift 4
  raw_error_file=$(mktemp -- "$secret_dir/.eventsales-r44-redis-raw-stderr.XXXXXXXX") || report_preflight_failure CLIENT_STDERR_CREATE_FAILED
  chmod 600 -- "$raw_error_file" || report_preflight_failure CLIENT_STDERR_PERMISSION_FAILED
  temporary_outputs+=("$raw_error_file")
  if {
    cat -- "$password_file"
    printf '\n'
  } | timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
      exec -T -i redis sh -c '
        unset REDISCLI_AUTH
        username=$1
        shift
        exec timeout 12s redis-cli -e --user "$username" --askpass --raw -h redis -p 6379 "$@"
      ' sh "$username" "$@" >"$output_file" 2>"$raw_error_file"; then
    status=0
  else
    status=$?
  fi
  if ! sed 's/Please input password:[[:space:]]*//g' "$raw_error_file" >"$error_file"; then
    rm -f -- "$raw_error_file" 2>/dev/null || true
    report_failure CLIENT_STDERR_FILTER_FAILED
  fi
  rm -f -- "$raw_error_file" 2>/dev/null || report_failure CLIENT_STDERR_CLEANUP_FAILED
  return "$status"
}

auth_client() {
  local password_file=$1 username=$2 output_file=$3
  shift 3
  auth_client_with_stderr "$password_file" "$username" "$output_file" /dev/null "$@"
}

auth_client_stdin() {
  local password_file=$1 username=$2 output_file=$3
  shift 3
  {
    cat -- "$password_file"
    printf '\n'
    printf '%s\n' "$@"
  } | timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
      exec -T -i redis sh -c '
        unset REDISCLI_AUTH
        exec timeout 12s redis-cli -e --user "$1" --askpass --raw -h redis -p 6379
      ' sh "$username" >"$output_file" 2>/dev/null
}

default_client_with_stderr() {
  local output_file=$1 error_file=$2
  shift 2
  timeout --signal=TERM --kill-after=2s "$DOCKER_TIMEOUT" \
    docker compose --project-name "$COMPOSE_PROJECT" --file "$COMPOSE_FILE" \
      exec -T redis sh -c '
        unset REDISCLI_AUTH
        exec timeout 12s redis-cli -e --user default --raw -h redis -p 6379 "$@"
      ' sh "$@" >"$output_file" 2>"$error_file"
}

default_client() {
  local output_file=$1
  shift
  default_client_with_stderr "$output_file" /dev/null "$@"
}

has_noperm_reply() {
  local error_file=$1
  grep -Eq '^NOPERM([[:space:]]|$)' "$error_file"
}

require_noperm() {
  local command_name=$1 password_file=$2 username=$3
  shift 3
  if [[ "$username" == eventsales_runtime && "$runtime_auth_proven" != true ]]; then
    report_failure "${username^^}_${command_name^^}_AUTH_NOT_PROVEN"
  fi
  if [[ "$username" == eventsales_stats && "$stats_auth_proven" != true ]]; then
    report_failure "${username^^}_${command_name^^}_AUTH_NOT_PROVEN"
  fi
  create_output_file
  local output_file=$created_output_path
  create_error_file
  local error_file=$created_error_path client_status
  if auth_client_with_stderr "$password_file" "$username" "$output_file" "$error_file" "$command_name" "$@"; then
    report_failure "${username^^}_${command_name^^}_UNEXPECTEDLY_ALLOWED"
  else
    client_status=$?
  fi
  if [[ "$client_status" != 1 ]]; then
    report_failure "${username^^}_${command_name^^}_CLIENT_EXIT_STATUS_NOT_REDIS_ERROR"
  fi
  if [[ -s "$output_file" ]]; then
    report_failure "${username^^}_${command_name^^}_UNEXPECTED_STDOUT"
  fi
  if ! has_noperm_reply "$error_file"; then
    report_failure "${username^^}_${command_name^^}_DENIAL_NOT_PROVEN"
  fi
}

require_default_noperm() {
  local command_name=$1
  shift
  if [[ "$default_auth_proven" != true ]]; then
    report_failure "DEFAULT_${command_name^^}_AUTH_NOT_PROVEN"
  fi
  create_output_file
  local output_file=$created_output_path
  create_error_file
  local error_file=$created_error_path client_status
  if default_client_with_stderr "$output_file" "$error_file" "$command_name" "$@"; then
    report_failure "DEFAULT_${command_name^^}_UNEXPECTEDLY_ALLOWED"
  else
    client_status=$?
  fi
  if [[ "$client_status" != 1 ]]; then
    report_failure "DEFAULT_${command_name^^}_CLIENT_EXIT_STATUS_NOT_REDIS_ERROR"
  fi
  if [[ -s "$output_file" ]]; then
    report_failure "DEFAULT_${command_name^^}_UNEXPECTED_STDOUT"
  fi
  if ! has_noperm_reply "$error_file"; then
    report_failure "DEFAULT_${command_name^^}_DENIAL_NOT_PROVEN"
  fi
}

nonce="${BASHPID}-$(date +%s%N)"
rate_key="eventsales:prod:r44:probe:${nonce}:rate"
hot_key="eventsales:prod:r44:probe:${nonce}:hot"
denied_write_key="eventsales:prod:r44:probe:${nonce}:denied-write"
stats_key="eventsales:prod:r44:probe:${nonce}:stats"
default_key="eventsales:prod:r44:probe:${nonce}:default"
outside_key="eventsales:r44:probe:${nonce}:outside"

create_output_file
output_file=$created_output_path
if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" PING; then
  report_failure RUNTIME_AUTH
fi
if [[ "$(<"$output_file")" != PONG ]]; then
  report_failure RUNTIME_AUTH
fi
runtime_auth_proven=true
record 'REDIS_STATE=RUNTIME_AUTH_PROVEN'
record 'REDIS_RUNTIME_AUTH=PASS'
printf 'REDIS_RUNTIME_AUTH=PASS\n'

for probe_key in "$rate_key" "$hot_key" "$denied_write_key" "$stats_key" "$default_key"; do
  create_output_file
  output_file=$created_output_path
  if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" EXISTS "$probe_key"; then
    report_failure RUNTIME_PROBE_KEY_CHECK
  fi
  if [[ "$(<"$output_file")" != 0 ]]; then
    report_failure RUNTIME_PROBE_KEY_ALREADY_EXISTS
  fi
done

create_output_file
output_file=$created_output_path
if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" SET "$denied_write_key" 0 PX "$RATE_LIMIT_TTL_MS"; then
  report_failure RUNTIME_DENIED_COMMAND_SETUP
fi
if [[ "$(<"$output_file")" != OK ]]; then
  report_failure RUNTIME_DENIED_COMMAND_SETUP
fi

create_output_file
output_file=$created_output_path
now_ms=$(date +%s%3N)
window_start=$((now_ms - RATE_LIMIT_TTL_MS))
if ! auth_client_stdin "$runtime_secret" eventsales_runtime "$output_file" \
  MULTI \
  "ZREMRANGEBYSCORE $rate_key -inf $window_start" \
  "ZADD $rate_key $now_ms r44-a" \
  "ZADD $rate_key $now_ms r44-b" \
  "ZCARD $rate_key" \
  "PEXPIRE $rate_key $RATE_LIMIT_TTL_MS" \
  EXEC; then
  report_failure RATE_LIMIT_SEQUENCE
fi
if ! python3 -I - "$output_file" <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

expected = ["OK", "QUEUED", "QUEUED", "QUEUED", "QUEUED", "QUEUED", "0", "1", "1", "2", "1"]
try:
    actual = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if actual == expected else 1)
PY
then
  report_failure RATE_LIMIT_SEQUENCE_RESULTS
fi
create_output_file
output_file=$created_output_path
if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" PTTL "$rate_key"; then
  report_failure RATE_LIMIT_TTL
fi
rate_ttl=$(<"$output_file")
if [[ ! "$rate_ttl" =~ ^[0-9]+$ ]] || ((rate_ttl < 1 || rate_ttl > RATE_LIMIT_TTL_MS)); then
  report_failure RATE_LIMIT_TTL
fi
record 'REDIS_STATE=RATE_LIMIT_SEQUENCE_PROVEN'
record 'REDIS_RATE_LIMIT_SEQUENCE=PASS'
printf 'REDIS_RATE_LIMIT_SEQUENCE=PASS\n'

create_output_file
output_file=$created_output_path
if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" SET "$hot_key" eventsales-r44-hot-state PX "$HOT_STATE_TTL_MS"; then
  report_failure HOT_STATE_SET
fi
if [[ "$(<"$output_file")" != OK ]]; then
  report_failure HOT_STATE_SET
fi
create_output_file
output_file=$created_output_path
if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" GET "$hot_key"; then
  report_failure HOT_STATE_GET
fi
if [[ "$(<"$output_file")" != eventsales-r44-hot-state ]]; then
  report_failure HOT_STATE_GET
fi
create_output_file
output_file=$created_output_path
if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" PTTL "$hot_key"; then
  report_failure HOT_STATE_TTL
fi
hot_ttl=$(<"$output_file")
if [[ ! "$hot_ttl" =~ ^[0-9]+$ ]] || ((hot_ttl < 1 || hot_ttl > HOT_STATE_TTL_MS)); then
  report_failure HOT_STATE_TTL
fi
record 'REDIS_STATE=HOT_STATE_PROVEN'
record 'REDIS_HOT_STATE=PASS'
printf 'REDIS_HOT_STATE=PASS\n'

scan_cursor=0
scan_found=false
for ((scan_iteration = 1; scan_iteration <= SCAN_MAX_ITERATIONS; scan_iteration += 1)); do
  create_output_file
  output_file=$created_output_path
  if ! auth_client "$runtime_secret" eventsales_runtime "$output_file" SCAN "$scan_cursor" MATCH 'eventsales:prod:*' COUNT "$SCAN_COUNT"; then
    report_failure BOUNDED_SCAN
  fi
  exec {scan_fd}<"$output_file"
  if ! IFS= read -r scan_cursor <&"$scan_fd" || [[ ! "$scan_cursor" =~ ^[0-9]+$ ]]; then
    exec {scan_fd}<&-
    report_failure BOUNDED_SCAN_RESPONSE
  fi
  while IFS= read -r scan_key <&"$scan_fd"; do
    if [[ "$scan_key" == "$hot_key" ]]; then
      scan_found=true
      break
    fi
  done
  exec {scan_fd}<&-
  if [[ "$scan_found" == true || "$scan_cursor" == 0 ]]; then
    break
  fi
done
if [[ "$scan_found" != true ]]; then
  report_failure BOUNDED_SCAN_KEY_NOT_FOUND
fi
record 'REDIS_STATE=BOUNDED_SCAN_PROVEN'
record 'REDIS_BOUNDED_SCAN=PASS'
printf 'REDIS_BOUNDED_SCAN=PASS\n'

create_output_file
output_file=$created_output_path
create_error_file
error_file=$created_error_path
if auth_client_with_stderr "$runtime_secret" eventsales_runtime "$output_file" "$error_file" SET "$outside_key" eventsales-r44-outside NX PX "$RATE_LIMIT_TTL_MS"; then
  client_status=0
else
  client_status=$?
fi
if [[ "$(<"$output_file")" == OK ]]; then
  record 'REDIS_OUT_OF_PREFIX_WRITE=UNEXPECTEDLY_ALLOWED'
  create_output_file
  cleanup_output=$created_output_path
  if auth_client "$runtime_secret" eventsales_runtime "$cleanup_output" DEL "$outside_key" && [[ "$(<"$cleanup_output")" == 1 ]]; then
    record 'REDIS_OUT_OF_PREFIX_CLEANUP=SCOPED_DEL_COMPLETED'
  else
    record 'REDIS_OUT_OF_PREFIX_CLEANUP=NOT_PERMITTED_OR_UNAVAILABLE'
  fi
  report_failure PREFIX_ISOLATION_NOT_ENFORCED
fi
if [[ "$client_status" != 1 ]] || [[ -s "$output_file" ]] || ! has_noperm_reply "$error_file"; then
  report_failure PREFIX_ISOLATION_DENIAL_NOT_PROVEN
fi
record 'REDIS_STATE=PREFIX_DENIAL_PROVEN'
record 'REDIS_PREFIX_DENY=PASS'
printf 'REDIS_PREFIX_DENY=PASS\n'
record 'REDIS_PREFIX_ALLOW=PASS'
printf 'REDIS_PREFIX_ALLOW=PASS\n'

require_noperm INFO "$runtime_secret" eventsales_runtime
require_noperm CONFIG "$runtime_secret" eventsales_runtime GET maxmemory
require_noperm INCR "$runtime_secret" eventsales_runtime "$denied_write_key"
require_noperm EVAL "$runtime_secret" eventsales_runtime 'return 1' 0
record 'REDIS_STATE=RUNTIME_DENIED_COMMANDS_PROVEN'
record 'REDIS_RUNTIME_DENIED_COMMANDS=PASS'
printf 'REDIS_RUNTIME_DENIED_COMMANDS=PASS\n'

create_output_file
output_file=$created_output_path
if ! auth_client "$stats_secret" eventsales_stats "$output_file" PING || [[ "$(<"$output_file")" != PONG ]]; then
  report_failure STATS_AUTH
fi
stats_auth_proven=true
create_output_file
output_file=$created_output_path
if ! auth_client "$stats_secret" eventsales_stats "$output_file" INFO; then
  report_failure STATS_INFO
fi
create_output_file
output_file=$created_output_path
if ! auth_client "$stats_secret" eventsales_stats "$output_file" CONFIG GET maxmemory; then
  report_failure STATS_CONFIG_GET
fi
if ! python3 -I - "$output_file" maxmemory 402653184 <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if lines == [sys.argv[2], sys.argv[3]] else 1)
PY
then
  report_failure MEMORY_LIMIT
fi
create_output_file
output_file=$created_output_path
if ! auth_client "$stats_secret" eventsales_stats "$output_file" CONFIG GET maxmemory-policy; then
  report_failure STATS_CONFIG_GET
fi
if ! python3 -I - "$output_file" maxmemory-policy noeviction <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if lines == [sys.argv[2], sys.argv[3]] else 1)
PY
then
  report_failure MEMORY_POLICY
fi
record 'REDIS_STATE=STATS_PROVEN'
record 'REDIS_MEMORY_POLICY=PASS'
printf 'REDIS_MEMORY_POLICY=PASS\n'

create_output_file
output_file=$created_output_path
if ! auth_client "$stats_secret" eventsales_stats "$output_file" CONFIG GET appendonly; then
  report_failure STATS_CONFIG_GET
fi
if ! python3 -I - "$output_file" appendonly no <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if lines == [sys.argv[2], sys.argv[3]] else 1)
PY
then
  report_failure PERSISTENCE_APPENDONLY
fi
create_output_file
output_file=$created_output_path
if ! auth_client "$stats_secret" eventsales_stats "$output_file" CONFIG GET save; then
  report_failure STATS_CONFIG_GET
fi
if ! python3 -I - "$output_file" <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

try:
    lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if lines == ["save", ""] else 1)
PY
then
  report_failure PERSISTENCE_SAVE
fi
record 'REDIS_STATE=PERSISTENCE_PROVEN'
record 'REDIS_PERSISTENCE=PASS'
printf 'REDIS_PERSISTENCE=PASS\n'

require_noperm GET "$stats_secret" eventsales_stats "$hot_key"
create_output_file
output_file=$created_output_path
create_error_file
error_file=$created_error_path
if auth_client_with_stderr "$stats_secret" eventsales_stats "$output_file" "$error_file" SET "$stats_key" eventsales-r44-stats NX PX "$RATE_LIMIT_TTL_MS"; then
  if [[ "$(<"$output_file")" == OK ]]; then
    report_failure STATS_WRITE_UNEXPECTEDLY_ALLOWED
  fi
  report_failure STATS_WRITE_DENIAL_NOT_PROVEN
else
  client_status=$?
fi
if [[ "$client_status" != 1 ]] || [[ -s "$output_file" ]] || ! has_noperm_reply "$error_file"; then
  report_failure STATS_WRITE_DENIAL_NOT_PROVEN
fi
record 'REDIS_STATE=STATS_KEY_DENIAL_PROVEN'
record 'REDIS_STATS=PASS'
printf 'REDIS_STATS=PASS\n'

create_output_file
output_file=$created_output_path
if ! default_client "$output_file" PING || [[ "$(<"$output_file")" != PONG ]]; then
  report_failure DEFAULT_PING
fi
default_auth_proven=true
record 'REDIS_STATE=DEFAULT_PING_PROVEN'
require_default_noperm GET "$hot_key"
create_output_file
output_file=$created_output_path
create_error_file
error_file=$created_error_path
if default_client_with_stderr "$output_file" "$error_file" SET "$default_key" eventsales-r44-default NX PX "$RATE_LIMIT_TTL_MS"; then
  report_failure DEFAULT_WRITE_UNEXPECTEDLY_ALLOWED
else
  client_status=$?
fi
if [[ "$client_status" != 1 ]] || [[ -s "$output_file" ]] || ! has_noperm_reply "$error_file"; then
  report_failure DEFAULT_WRITE_DENIAL_NOT_PROVEN
fi
require_default_noperm INFO
require_default_noperm CONFIG GET maxmemory
record 'REDIS_STATE=DEFAULT_IDENTITY_PROVEN'
record 'REDIS_DEFAULT_IDENTITY=PASS'
printf 'REDIS_DEFAULT_IDENTITY=PASS\n'

record 'REDIS_STATE=PASS'
record 'REDIS_PROBE=PASS'
printf 'REDIS_PROBE=PASS\n'
