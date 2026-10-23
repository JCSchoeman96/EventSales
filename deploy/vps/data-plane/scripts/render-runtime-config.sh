#!/bin/bash
set -euo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL

readonly -a SECRET_FILES=(
  postgres_bootstrap_password
  eventsales_migrator_password
  eventsales_runtime_server_password
  eventsales_runtime_client_password
  eventsales_backup_password
  redis_runtime_password
  redis_stats_password
)
readonly -a RENDERED_FILES=(
  pgbouncer.ini
  pgbouncer_users.txt
  redis-users.acl
)

temporary_files=()

cleanup_temporary_files() {
  local temporary_file
  for temporary_file in "${temporary_files[@]}"; do
    if [[ -n "$temporary_file" ]]; then
      rm -f -- "$temporary_file" 2>/dev/null || true
    fi
  done
}

trap cleanup_temporary_files EXIT

stop() {
  printf 'STOP=%s\n' "$1" >&2
  exit 1
}

if (($# != 1)); then
  printf 'STOP=ARGUMENT_COUNT\n' >&2
  exit 2
fi

if ((EUID != 0)); then
  stop ROOT_REQUIRED
fi

secret_dir=$1
if [[ "$secret_dir" != /* || "$secret_dir" == / || "$secret_dir" == */ || "$secret_dir" == *//* ]]; then
  stop SECRET_DIRECTORY_PATH_NOT_CANONICAL_ABSOLUTE
fi

relative_path=${secret_dir#/}
IFS='/' read -r -a path_parts <<<"$relative_path"
if ((${#path_parts[@]} == 0)); then
  stop SECRET_DIRECTORY_PATH_INVALID
fi

current_path=/
for part in "${path_parts[@]}"; do
  if [[ -z "$part" || "$part" == . || "$part" == .. ]]; then
    stop SECRET_DIRECTORY_PATH_COMPONENT_INVALID
  fi

  current_path="${current_path%/}/$part"
  if [[ -L "$current_path" ]]; then
    stop SECRET_DIRECTORY_SYMLINK
  fi
  if [[ ! -d "$current_path" ]]; then
    stop SECRET_DIRECTORY_NOT_DIRECTORY
  fi
  path_metadata=$(stat -c '%u:%a' -- "$current_path" 2>/dev/null) || stop SECRET_DIRECTORY_ANCESTOR_METADATA_UNAVAILABLE
  path_owner=${path_metadata%%:*}
  path_mode=${path_metadata#*:}
  if [[ "$path_owner" != 0 ]]; then
    stop SECRET_DIRECTORY_ANCESTOR_NOT_ROOT_OWNED
  fi
  path_mode_value=$((8#$path_mode))
  if (( (path_mode_value & 0022) != 0 && (path_mode_value & 01000) == 0 )); then
    stop SECRET_DIRECTORY_ANCESTOR_UNSAFE_WRITABLE_MODE
  fi
done

directory_metadata=$(stat -c '%u:%g:%a' -- "$secret_dir" 2>/dev/null) || stop SECRET_DIRECTORY_METADATA_UNAVAILABLE
if [[ "$directory_metadata" != 0:0:700 ]]; then
  stop SECRET_DIRECTORY_METADATA_MISMATCH
fi

check_secret_file() {
  local name=$1
  local expected_metadata=$2
  local secret_path="$secret_dir/$name"
  local file_metadata byte_count

  if [[ -L "$secret_path" ]]; then
    stop "SECRET_INPUT_SYMLINK file=$name"
  fi
  if [[ ! -f "$secret_path" ]]; then
    stop "SECRET_INPUT_NOT_REGULAR file=$name"
  fi

  file_metadata=$(stat -c '%u:%g:%a' -- "$secret_path" 2>/dev/null) || stop "SECRET_INPUT_METADATA_UNAVAILABLE file=$name"
  if [[ "$file_metadata" != "$expected_metadata" ]]; then
    stop "SECRET_INPUT_METADATA_MISMATCH file=$name"
  fi

  byte_count=$(stat -c '%s' -- "$secret_path" 2>/dev/null) || stop "SECRET_INPUT_SIZE_UNAVAILABLE file=$name"
  if [[ "$byte_count" != 64 ]] || ! LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$secret_path" 2>/dev/null; then
    stop "SECRET_INPUT_FORMAT_INVALID file=$name"
  fi
}

for name in "${SECRET_FILES[@]}"; do
  if [[ "$name" == postgres_bootstrap_password ]]; then
    check_secret_file "$name" 0:70:440
  else
    check_secret_file "$name" 0:0:400
  fi
done

for name in "${RENDERED_FILES[@]}"; do
  output_path="$secret_dir/$name"
  if [[ -e "$output_path" || -L "$output_path" ]]; then
    stop "FINAL_OUTPUT_ALREADY_EXISTS file=$name"
  fi
done

shopt -s dotglob nullglob
directory_entries=("$secret_dir"/*)
for entry in "${directory_entries[@]}"; do
  entry_name=${entry##*/}
  recognized=false
  for name in "${SECRET_FILES[@]}"; do
    if [[ "$entry_name" == "$name" ]]; then
      recognized=true
      break
    fi
  done
  if [[ "$recognized" != true ]]; then
    stop UNEXPECTED_SECRET_DIRECTORY_ENTRY
  fi
done

script_path=${BASH_SOURCE[0]}
if [[ -L "$script_path" ]]; then
  stop SCRIPT_PATH_SYMLINK
fi
script_dir=$(cd -- "$(dirname -- "$script_path")" && pwd -P) || stop SCRIPT_DIRECTORY_UNAVAILABLE
template_dir="${script_dir%/scripts}/templates"
pgbouncer_template="$template_dir/pgbouncer.ini.template"
redis_template="$template_dir/redis-users.acl.template"
if [[ -L "$pgbouncer_template" || ! -f "$pgbouncer_template" ]]; then
  stop PGBOUNCER_TEMPLATE_UNAVAILABLE
fi
if [[ -L "$redis_template" || ! -f "$redis_template" ]]; then
  stop REDIS_TEMPLATE_UNAVAILABLE
fi

temporary_ini=$(mktemp -- "$secret_dir/.pgbouncer.ini.XXXXXX" 2>/dev/null) || stop TEMPORARY_OUTPUT_CREATE_FAILED
temporary_files+=("$temporary_ini")
temporary_users=$(mktemp -- "$secret_dir/.pgbouncer_users.txt.XXXXXX" 2>/dev/null) || stop TEMPORARY_OUTPUT_CREATE_FAILED
temporary_files+=("$temporary_users")
temporary_acl=$(mktemp -- "$secret_dir/.redis-users.acl.XXXXXX" 2>/dev/null) || stop TEMPORARY_OUTPUT_CREATE_FAILED
temporary_files+=("$temporary_acl")

if ! python3 -I - \
  "$pgbouncer_template" \
  "$redis_template" \
  "$secret_dir/eventsales_runtime_server_password" \
  "$secret_dir/eventsales_runtime_client_password" \
  "$secret_dir/redis_runtime_password" \
  "$secret_dir/redis_stats_password" \
  "$temporary_ini" \
  "$temporary_users" \
  "$temporary_acl" >/dev/null 2>&1 <<'PY'
import base64
import hashlib
import hmac
import re
import secrets
import sys
from pathlib import Path


def stop():
    print("STOP=RENDER_TRANSFORM_FAILED", file=sys.stderr)
    raise SystemExit(1)


try:
    (
        pgbouncer_template_path,
        redis_template_path,
        server_password_path,
        client_password_path,
        redis_runtime_password_path,
        redis_stats_password_path,
        pgbouncer_output_path,
        users_output_path,
        redis_output_path,
    ) = map(Path, sys.argv[1:])

    def read_password(path):
        value = path.read_bytes()
        if len(value) != 64 or re.fullmatch(rb"[0-9a-f]{64}", value) is None:
            stop()
        return value

    server_password = read_password(server_password_path)
    client_password = read_password(client_password_path)
    redis_runtime_password = read_password(redis_runtime_password_path)
    redis_stats_password = read_password(redis_stats_password_path)

    pgbouncer_template = pgbouncer_template_path.read_bytes()
    redis_template = redis_template_path.read_bytes()

    server_placeholder = b"__EVENTSALES_RUNTIME_SERVER_PASSWORD__"
    if pgbouncer_template.count(server_placeholder) != 1:
        stop()
    pgbouncer_config = pgbouncer_template.replace(server_placeholder, server_password)

    iterations = 4096
    salt = secrets.token_bytes(16)
    salted_password = hashlib.pbkdf2_hmac("sha256", client_password, salt, iterations)
    client_key = hmac.new(salted_password, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted_password, b"Server Key", hashlib.sha256).digest()

    def encode(value):
        return base64.b64encode(value)

    verifier = (
        b"SCRAM-SHA-256$"
        + str(iterations).encode("ascii")
        + b":"
        + encode(salt)
        + b"$"
        + encode(stored_key)
        + b":"
        + encode(server_key)
    )
    users_file = b'"eventsales_runtime" "' + verifier + b'"\n'

    runtime_placeholder = b"__EVENTSALES_REDIS_RUNTIME_PASSWORD_SHA256_64HEX__"
    stats_placeholder = b"__EVENTSALES_REDIS_STATS_PASSWORD_SHA256_64HEX__"
    if redis_template.count(runtime_placeholder) != 1 or redis_template.count(stats_placeholder) != 1:
        stop()
    redis_config = redis_template.replace(
        runtime_placeholder, hashlib.sha256(redis_runtime_password).hexdigest().encode("ascii")
    ).replace(stats_placeholder, hashlib.sha256(redis_stats_password).hexdigest().encode("ascii"))

    placeholder_pattern = re.compile(rb"__[A-Z0-9_]+__")
    if any(
        placeholder_pattern.search(value)
        for value in (pgbouncer_config, users_file, redis_config)
    ):
        stop()

    pgbouncer_output_path.write_bytes(pgbouncer_config)
    users_output_path.write_bytes(users_file)
    redis_output_path.write_bytes(redis_config)
except SystemExit:
    raise
except Exception:
    stop()
PY
then
  stop RENDER_TRANSFORM_FAILED
fi

publish_output() {
  local temporary_path=$1
  local output_name=$2
  local final_path="$secret_dir/$output_name"

  if ! chown 0:65532 -- "$temporary_path" 2>/dev/null || ! chmod 0440 -- "$temporary_path" 2>/dev/null; then
    stop "FINAL_OUTPUT_PERMISSIONS_FAILED file=$output_name"
  fi

  file_metadata=$(stat -c '%u:%g:%a' -- "$temporary_path" 2>/dev/null) || stop "FINAL_OUTPUT_METADATA_UNAVAILABLE file=$output_name"
  if [[ "$file_metadata" != 0:65532:440 ]]; then
    stop "FINAL_OUTPUT_METADATA_MISMATCH file=$output_name"
  fi

  if ! ln -T -- "$temporary_path" "$final_path" 2>/dev/null; then
    stop "FINAL_OUTPUT_PLACEMENT_FAILED file=$output_name"
  fi
  if ! rm -- "$temporary_path" 2>/dev/null; then
    stop "TEMPORARY_OUTPUT_REMOVE_FAILED file=$output_name"
  fi
}

publish_output "$temporary_ini" pgbouncer.ini
publish_output "$temporary_users" pgbouncer_users.txt
publish_output "$temporary_acl" redis-users.acl

for name in "${RENDERED_FILES[@]}"; do
  output_path="$secret_dir/$name"
  if [[ -L "$output_path" || ! -f "$output_path" ]]; then
    stop "FINAL_OUTPUT_NOT_REGULAR file=$name"
  fi
  file_metadata=$(stat -c '%u:%g:%a' -- "$output_path" 2>/dev/null) || stop "FINAL_OUTPUT_METADATA_UNAVAILABLE file=$name"
  if [[ "$file_metadata" != 0:65532:440 ]]; then
    stop "FINAL_OUTPUT_METADATA_MISMATCH file=$name"
  fi
done

printf 'RENDER_STATE=RENDERED COUNT=3 OWNER=0 GROUP=65532 MODE=440 PLACEHOLDERS=NONE\n'
for name in "${RENDERED_FILES[@]}"; do
  printf 'RENDERED_FILE=%s STATE=RENDERED OWNER=0 GROUP=65532 MODE=440\n' "$name"
done
