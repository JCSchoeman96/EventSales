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

target_dir=$1
if [[ "$target_dir" != /* || "$target_dir" == / || "$target_dir" == */ || "$target_dir" == *//* ]]; then
  stop TARGET_PATH_NOT_CANONICAL_ABSOLUTE
fi

relative_path=${target_dir#/}
IFS='/' read -r -a path_parts <<<"$relative_path"
if ((${#path_parts[@]} == 0)); then
  stop TARGET_PATH_INVALID
fi

current_path=/
last_part_index=$((${#path_parts[@]} - 1))
for index in "${!path_parts[@]}"; do
  part=${path_parts[$index]}
  if [[ -z "$part" || "$part" == . || "$part" == .. ]]; then
    stop TARGET_PATH_COMPONENT_INVALID
  fi

  current_path="${current_path%/}/$part"
  if [[ -L "$current_path" ]]; then
    stop TARGET_PATH_SYMLINK
  fi

  if ((index < last_part_index)); then
    if [[ ! -d "$current_path" ]]; then
      stop TARGET_ANCESTOR_NOT_DIRECTORY
    fi
    ancestor_metadata=$(stat -c '%u:%a' -- "$current_path" 2>/dev/null) || stop TARGET_ANCESTOR_METADATA_UNAVAILABLE
    ancestor_owner=${ancestor_metadata%%:*}
    ancestor_mode=${ancestor_metadata#*:}
    if [[ "$ancestor_owner" != 0 ]]; then
      stop TARGET_ANCESTOR_NOT_ROOT_OWNED
    fi
    ancestor_mode_value=$((8#$ancestor_mode))
    if (( (ancestor_mode_value & 0022) != 0 && (ancestor_mode_value & 01000) == 0 )); then
      stop TARGET_ANCESTOR_UNSAFE_WRITABLE_MODE
    fi
  elif [[ -e "$current_path" || -L "$current_path" ]]; then
    stop TARGET_ALREADY_EXISTS
  fi
done

if ! mkdir -m 0700 -- "$target_dir" 2>/dev/null; then
  stop TARGET_CREATE_FAILED
fi
if ! chown 0:0 -- "$target_dir" 2>/dev/null; then
  stop TARGET_OWNERSHIP_FAILED
fi
if ! chmod 0700 -- "$target_dir" 2>/dev/null; then
  stop TARGET_MODE_FAILED
fi

directory_metadata=$(stat -c '%u:%g:%a' -- "$target_dir" 2>/dev/null) || stop TARGET_METADATA_UNAVAILABLE
if [[ "$directory_metadata" != 0:0:700 ]]; then
  stop TARGET_METADATA_MISMATCH
fi

for name in "${SECRET_FILES[@]}"; do
  secret_path="$target_dir/$name"
  if [[ -e "$secret_path" || -L "$secret_path" ]]; then
    stop "SECRET_FILE_ALREADY_EXISTS file=$name"
  fi

  if ! openssl rand -hex 32 2>/dev/null | tr -d '\n' 2>/dev/null >"$secret_path"; then
    stop "SECRET_GENERATION_FAILED file=$name"
  fi

  byte_count=$(stat -c '%s' -- "$secret_path" 2>/dev/null) || stop "SECRET_SIZE_UNAVAILABLE file=$name"
  if [[ "$byte_count" != 64 ]] || ! LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$secret_path" 2>/dev/null; then
    stop "SECRET_FORMAT_INVALID file=$name"
  fi

  if [[ "$name" == postgres_bootstrap_password ]]; then
    expected_metadata=0:70:440
    if ! chown 0:70 -- "$secret_path" 2>/dev/null || ! chmod 0440 -- "$secret_path" 2>/dev/null; then
      stop "SECRET_PERMISSIONS_FAILED file=$name"
    fi
  else
    expected_metadata=0:0:400
    if ! chown 0:0 -- "$secret_path" 2>/dev/null || ! chmod 0400 -- "$secret_path" 2>/dev/null; then
      stop "SECRET_PERMISSIONS_FAILED file=$name"
    fi
  fi

  file_metadata=$(stat -c '%u:%g:%a' -- "$secret_path" 2>/dev/null) || stop "SECRET_METADATA_UNAVAILABLE file=$name"
  if [[ "$file_metadata" != "$expected_metadata" ]]; then
    stop "SECRET_METADATA_MISMATCH file=$name"
  fi
done

for ((left_index = 0; left_index < ${#SECRET_FILES[@]}; left_index++)); do
  for ((right_index = left_index + 1; right_index < ${#SECRET_FILES[@]}; right_index++)); do
    left_path="$target_dir/${SECRET_FILES[$left_index]}"
    right_path="$target_dir/${SECRET_FILES[$right_index]}"
    if cmp -s -- "$left_path" "$right_path"; then
      stop SECRET_VALUES_NOT_UNIQUE
    else
      compare_status=$?
      if ((compare_status != 1)); then
        stop SECRET_COMPARISON_FAILED
      fi
    fi
  done
done

printf 'SECRET_STATE=GENERATED COUNT=7 UNIQUE=YES DIRECTORY_OWNER=0 DIRECTORY_GROUP=0 DIRECTORY_MODE=700\n'
for name in "${SECRET_FILES[@]}"; do
  if [[ "$name" == postgres_bootstrap_password ]]; then
    printf 'SECRET_FILE=%s STATE=GENERATED OWNER=0 GROUP=70 MODE=440 BYTES=64\n' "$name"
  else
    printf 'SECRET_FILE=%s STATE=GENERATED OWNER=0 GROUP=0 MODE=400 BYTES=64\n' "$name"
  fi
done
