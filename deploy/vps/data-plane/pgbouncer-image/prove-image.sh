#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../../../" && pwd -P)
IMAGE_DIR="$REPO_ROOT/deploy/vps/data-plane/pgbouncer-image"
RUST_BUILDER='rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9'
BASE_IMAGE_REFERENCE='dhi.io/pgbouncer:1.26.1-debian13@sha256:78fe21ad5b7c1ab497e9828eea9b951f9d6a58eb638946ddc61ef1f99737f1b1'
LOCAL_IMAGE_TAG='eventsales-pgbouncer:r3-4-local'
SOURCE_URL='https://github.com/JCSchoeman96/EventSales'
PROBE_PATH='/usr/local/bin/eventsales-pgbouncer-healthcheck'

RUN_DIR=''
RUN_ID=''
TMP_ROOT=''
UNIT_CONTAINER_ID=''
BASE_CONTAINER_ID=''
CANDIDATE_CONTAINER_ID=''
HELPER_CONTAINER_ID=''
HELPER_BUILD_CONTAINER_NAME=''
TASK4_HELPER_CONTAINER_NAME=''
TASK4_HELPER_SEQUENCE=0
NETWORK_ID=''
NETWORK_NAME=''
CANDIDATE_IMAGE_ID=''
BASE_IMAGE_ID=''

usage() {
  printf 'Usage: bash %s <unit|build|static|integration|self-test|all> [image-reference]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_frozen_base_image() {
  local image_id

  if image_id=$(docker image inspect --format '{{.Id}}' "$BASE_IMAGE_REFERENCE" 2>/dev/null) && [[ -n "$image_id" ]]; then
    printf '%s\n' "$image_id"
    return 0
  fi

  printf 'Frozen base is not locally inspectable; pulling the exact linux/amd64 digest.\n' >&2
  if ! docker pull --platform linux/amd64 "$BASE_IMAGE_REFERENCE" >&2; then
    printf 'ERROR: failed to pull frozen base image: %s\n' "$BASE_IMAGE_REFERENCE" >&2
    return 1
  fi

  if ! image_id=$(docker image inspect --format '{{.Id}}' "$BASE_IMAGE_REFERENCE"); then
    printf 'ERROR: frozen base image did not resolve after pulling: %s\n' "$BASE_IMAGE_REFERENCE" >&2
    return 1
  fi
  if [[ -z "$image_id" ]]; then
    printf 'ERROR: frozen base image resolved to an empty image ID: %s\n' "$BASE_IMAGE_REFERENCE" >&2
    return 1
  fi

  printf '%s\n' "$image_id"
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
  if [[ -n "$BASE_CONTAINER_ID" ]]; then
    docker rm -f "$BASE_CONTAINER_ID" >/dev/null 2>&1 || cleanup_failed=1
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
  if [[ -n "$TASK4_HELPER_CONTAINER_NAME" ]]; then
    if [[ "$TASK4_HELPER_CONTAINER_NAME" =~ ^eventsales-r3-4-${RUN_ID}-task4-[0-9]+$ ]]; then
      if helper_build_id=$(docker container inspect --format '{{.Id}}' "$TASK4_HELPER_CONTAINER_NAME" 2>/dev/null); then
        helper_build_run_id=$(docker container inspect --format '{{index .Config.Labels "eventsales.r3-4.proof-run"}}' "$helper_build_id" 2>/dev/null) || helper_build_run_id=''
        if [[ "$helper_build_run_id" == "$RUN_ID" ]]; then
          if ! docker rm -f "$helper_build_id" >/dev/null 2>&1; then
            if docker container inspect "$helper_build_id" >/dev/null 2>&1; then
              cleanup_failed=1
            fi
          fi
        else
          printf 'Refusing to remove Task-4 helper without this run label: %s\n' "$TASK4_HELPER_CONTAINER_NAME" >&2
          cleanup_failed=1
        fi
      elif ! docker info >/dev/null 2>&1; then
        printf 'Unable to inspect Task-4 helper during cleanup: %s\n' "$TASK4_HELPER_CONTAINER_NAME" >&2
        cleanup_failed=1
      fi
    else
      printf 'Refusing to remove unexpected Task-4 helper name: %s\n' "$TASK4_HELPER_CONTAINER_NAME" >&2
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

run_task4_helper() {
  local helper_mode=$1
  TASK4_HELPER_SEQUENCE=$((TASK4_HELPER_SEQUENCE + 1))
  TASK4_HELPER_CONTAINER_NAME="eventsales-r3-4-${RUN_ID}-task4-${TASK4_HELPER_SEQUENCE}"
  timeout --signal=KILL 120s docker run --rm -i \
    --name "$TASK4_HELPER_CONTAINER_NAME" \
    --label "eventsales.r3-4.proof-run=$RUN_ID" \
    --platform linux/amd64 \
    --network none \
    --mount "type=bind,src=$RUN_DIR,dst=/work" \
    "$RUST_BUILDER" \
    /bin/sh -s "$helper_mode" <<'TASK4_HELPER'
#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
PROBE_PATH='/usr/local/bin/eventsales-pgbouncer-healthcheck'

manifest() {
  root=$1
  output=$2
  raw_output="${output}.raw"
  [ -d "$root" ] || { printf 'manifest root is missing: %s\n' "$root" >&2; return 1; }
  find "$root" -mindepth 1 -exec sh -c '
    root=$1
    object=$2
    relative=${object#"$root"/}
    path_hex=$(printf "%s" "$relative" | od -An -tx1 | tr -d " \n")
    kind=$(stat -c "%F" "$object")
    mode=$(stat -c "%a" "$object")
    uid=$(stat -c "%u" "$object")
    gid=$(stat -c "%g" "$object")
    size=-
    extra=-
    case "$kind" in
      "regular file")
        size=$(stat -c "%s" "$object")
        digest=$(sha256sum < "$object")
        set -- $digest
        extra=$1
        ;;
      "symbolic link")
        extra=$(readlink -n "$object" | od -An -tx1 | tr -d " \n")
        ;;
    esac
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$path_hex" "$kind" "$mode" "$uid" "$gid" "$size" "$extra"
  ' task4-manifest "$root" {} \; > "$raw_output"
  sort "$raw_output" > "$output"
}

verify_elf() {
  candidate=$1
  if [ ! -f "$candidate" ] || [ ! -x "$candidate" ]; then
    printf 'ELF verifier: missing or non-executable file\n' >&2
    return 1
  fi
  size_output=$(wc -c < "$candidate") || { printf 'ELF verifier: cannot measure file\n' >&2; return 1; }
  set -- $size_output
  size=${1-}
  case "$size" in ""|*[!0-9]*) printf 'ELF verifier: invalid size\n' >&2; return 1 ;; esac
  if [ "$size" -gt 2097152 ]; then
    printf 'ELF verifier: file exceeds 2097152 bytes\n' >&2
    return 1
  fi
  header=$(readelf -hW "$candidate") || { printf 'ELF verifier: invalid ELF header\n' >&2; return 1; }
  case "$header" in *"Machine:"*"Advanced Micro Devices X86-64"*) ;; *) printf 'ELF verifier: architecture is not x86-64\n' >&2; return 1 ;; esac
  program_headers=$(readelf -lW "$candidate") || { printf 'ELF verifier: cannot read program headers\n' >&2; return 1; }
  case "$program_headers" in *INTERP*) printf 'ELF verifier: PT_INTERP is present\n' >&2; return 1 ;; esac
  dynamic_section=$(readelf -dW "$candidate" 2>&1) || { printf 'ELF verifier: cannot read dynamic section\n' >&2; return 1; }
  case "$dynamic_section" in *NEEDED*) printf 'ELF verifier: DT_NEEDED is present\n' >&2; return 1 ;; esac
  printf 'PROBE_SIZE_BYTES=%s\nPROBE_X86_64=YES\nPROBE_PT_INTERP=NONE\nPROBE_DT_NEEDED=NONE\n' "$size"
}

extract_manifest() {
  archive=$1
  root=$2
  output=$3
  mkdir -p "$root"
  tar -xpf "$archive" -C "$root"
  manifest "$root" "$output"
}

static_proof() {
  extract_manifest /work/base-rootfs.tar /work/base-rootfs /work/base.manifest
  extract_manifest /work/candidate-rootfs.tar /work/candidate-rootfs /work/candidate.manifest
  verify_elf "/work/candidate-rootfs${PROBE_PATH}"
  rm -rf /work/base-rootfs /work/candidate-rootfs
}

self_test() {
  chown 1234:2345 /work/self-test/changed-owner/etc/pgbouncer.ini
  chown -h 3456:4567 /work/self-test/changed-link-owner/etc/current
  for fixture in base allowed removed replaced extra changed-mode changed-owner changed-link changed-link-owner replaced-type; do
    manifest "/work/self-test/$fixture" "/work/self-test/$fixture.manifest"
  done

  cat > /work/self-test/elf-fixture.rs <<'RUST'
fn main() {}
RUST
  rustc --edition=2021 --target x86_64-unknown-linux-musl -C opt-level=3 -C strip=symbols \
    /work/self-test/elf-fixture.rs -o /work/self-test/static-elf
  verify_elf /work/self-test/static-elf > /work/self-test/static-elf.report 2>&1

  cp -L /usr/bin/readelf /work/self-test/dynamic-elf
  chmod 0755 /work/self-test/dynamic-elf
  dynamic_size_output=$(wc -c < /work/self-test/dynamic-elf)
  set -- $dynamic_size_output
  dynamic_size=$1
  [ "$dynamic_size" -le 2097152 ] || { printf 'dynamic fixture exceeds size ceiling\n' >&2; return 1; }
  dynamic_header=$(readelf -hW /work/self-test/dynamic-elf)
  case "$dynamic_header" in *"Machine:"*"Advanced Micro Devices X86-64"*) ;; *) printf 'dynamic fixture is not x86-64\n' >&2; return 1 ;; esac
  dynamic_program_headers=$(readelf -lW /work/self-test/dynamic-elf)
  case "$dynamic_program_headers" in *INTERP*) ;; *) printf 'dynamic fixture lacks PT_INTERP\n' >&2; return 1 ;; esac
  dynamic_section=$(readelf -dW /work/self-test/dynamic-elf 2>&1)
  case "$dynamic_section" in *NEEDED*) ;; *) printf 'dynamic fixture lacks DT_NEEDED\n' >&2; return 1 ;; esac
  if verify_elf /work/self-test/dynamic-elf > /work/self-test/dynamic-elf.report 2>&1; then
    printf 'ELF verifier accepted dynamic fixture\n' >&2
    return 1
  fi

  cp -p /work/self-test/static-elf /work/self-test/oversize-elf
  printf '%02100000d' 0 >> /work/self-test/oversize-elf
  [ -x /work/self-test/oversize-elf ] || { printf 'oversize fixture is not executable\n' >&2; return 1; }
  oversize_header=$(readelf -hW /work/self-test/oversize-elf)
  case "$oversize_header" in *"Machine:"*"Advanced Micro Devices X86-64"*) ;; *) printf 'oversize fixture is not x86-64\n' >&2; return 1 ;; esac
  oversize_size_output=$(wc -c < /work/self-test/oversize-elf)
  set -- $oversize_size_output
  oversize_size=$1
  [ "$oversize_size" -gt 2097152 ] || { printf 'oversize fixture is below size ceiling\n' >&2; return 1; }
  if verify_elf /work/self-test/oversize-elf > /work/self-test/oversize-elf.report 2>&1; then
    printf 'ELF verifier accepted oversize fixture\n' >&2
    return 1
  fi
  printf 'SELF_TEST_STATIC_ELF=PASS\nSELF_TEST_DYNAMIC_ELF_REJECTED=YES\nSELF_TEST_OVERSIZE_REJECTED=YES\n'
}

case "${1-}" in
  static) static_proof ;;
  self-test) self_test ;;
  *) printf 'unknown helper mode\n' >&2; exit 2 ;;
esac
TASK4_HELPER
}

write_filesystem_fixture() {
  local root=$1
  local variant=$2
  local link_target=pgbouncer.ini
  mkdir -p "$root/etc" "$root/lib" "$root/usr/local/bin"
  [[ "$variant" == changed-link ]] && link_target=other.ini
  case "$variant" in
    removed) ;;
    replaced) printf 'synthetic configuratioN\n' > "$root/etc/pgbouncer.ini" ;;
    replaced-type) mkdir -p "$root/etc/pgbouncer.ini" ;;
    *) printf 'synthetic configuration\n' > "$root/etc/pgbouncer.ini" ;;
  esac
  [[ "$variant" == changed-mode ]] && chmod 0600 "$root/etc/pgbouncer.ini"
  ln -s "$link_target" "$root/etc/current"
  printf 'synthetic base library\n' > "$root/lib/libfixture.so"
  if [[ "$variant" == extra ]]; then
    printf 'unapproved library\n' > "$root/lib/libextra.so"
  fi
  if [[ "$variant" == allowed ]]; then
    printf 'synthetic executable fixture\n' > "$root${PROBE_PATH}"
    chmod 0755 "$root${PROBE_PATH}"
  fi
}

write_config_fixture() {
  local path=$1
  local user=$2
  local entrypoint=$3
  local cmd=$4
  local config_hash=$5
  local label_hash=$6
  local source_valid=$7
  local revision_valid=$8
  printf 'linux\namd64\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$user" "$entrypoint" "$cmd" "$config_hash" "$label_hash" "$source_valid" "$revision_valid" > "$path"
}

manifest_delta_check() {
  local base_manifest=$1
  local candidate_manifest=$2
  local allowed_path=${PROBE_PATH#/}
  local allowed_path_hex
  local path record kind mode uid gid size extra
  local removed=0
  local modified=0
  local added=0
  local added_path=''
  local added_record=''
  local added_kind=''
  local added_mode=''
  local added_uid=''
  local added_gid=''
  local added_size=''
  local added_extra=''
  local -A base_entries=()
  local -A candidate_entries=()

  [[ -r "$base_manifest" && -r "$candidate_manifest" ]] || return 1
  allowed_path_hex=$(printf '%s' "$allowed_path" | od -An -tx1 | tr -d ' \n')
  while IFS=$'\t' read -r path kind mode uid gid size extra; do
    [[ -n "$path" ]] || continue
    base_entries["$path"]="$kind|$mode|$uid|$gid|$size|$extra"
  done < "$base_manifest"
  while IFS=$'\t' read -r path kind mode uid gid size extra; do
    [[ -n "$path" ]] || continue
    candidate_entries["$path"]="$kind|$mode|$uid|$gid|$size|$extra"
  done < "$candidate_manifest"

  for path in "${!base_entries[@]}"; do
    if [[ ${candidate_entries[$path]+present} != present ]]; then
      removed=$((removed + 1))
    elif [[ "${base_entries[$path]}" != "${candidate_entries[$path]}" ]]; then
      modified=$((modified + 1))
    fi
  done
  for path in "${!candidate_entries[@]}"; do
    if [[ ${base_entries[$path]+present} != present ]]; then
      added=$((added + 1))
      added_path=$path
      added_record=${candidate_entries[$path]}
    fi
  done

  FS_BASE_ENTRY_COUNT=${#base_entries[@]}
  FS_CANDIDATE_ENTRY_COUNT=${#candidate_entries[@]}
  FS_REMOVED_BASE_ENTRIES=$removed
  FS_MODIFIED_BASE_ENTRIES=$modified
  FS_ADDED_ENTRIES=$added
  ONLY_APPROVED_PROBE_ADDED=NO

  if ((removed == 0 && modified == 0 && added == 1)) && [[ "$added_path" == "$allowed_path_hex" ]]; then
    IFS='|' read -r added_kind added_mode added_uid added_gid added_size added_extra <<< "$added_record"
    if [[ "$added_kind" == 'regular file' && "$added_mode" == 755 ]]; then
      ONLY_APPROVED_PROBE_ADDED=YES
      return 0
    fi
  fi
  return 1
}

image_config_contract() {
  local base_snapshot=$1
  local candidate_snapshot=$2
  local -a base_fields=()
  local -a candidate_fields=()
  mapfile -t base_fields < "$base_snapshot"
  mapfile -t candidate_fields < "$candidate_snapshot"
  [[ ${#base_fields[@]} -eq 9 && ${#candidate_fields[@]} -eq 9 ]] || return 1
  [[ "${base_fields[0]}" == linux && "${candidate_fields[0]}" == linux ]] || return 1
  [[ "${base_fields[1]}" == amd64 && "${candidate_fields[1]}" == amd64 ]] || return 1
  [[ "${base_fields[2]}" == '"65532"' && "${candidate_fields[2]}" == '"65532"' ]] || return 1
  [[ "${base_fields[3]}" == '["pgbouncer"]' && "${candidate_fields[3]}" == '["pgbouncer"]' ]] || return 1
  [[ "${base_fields[4]}" == '["/etc/pgbouncer/pgbouncer.ini"]' && "${candidate_fields[4]}" == '["/etc/pgbouncer/pgbouncer.ini"]' ]] || return 1
  [[ "${base_fields[5]}" == "${candidate_fields[5]}" ]] || return 1
  [[ "${base_fields[6]}" == "${candidate_fields[6]}" ]] || return 1
  [[ "${candidate_fields[7]}" == YES && "${candidate_fields[8]}" == YES ]] || return 1
  return 0
}

capture_image_config_snapshot() {
  local image_id=$1
  local destination=$2
  local field_template
  local config_template
  local label_template
  local fields_path="${destination}.fields"
  local config_hash_line
  local labels_hash_line
  local config_hash
  local labels_hash
  local source_label
  local revision_label
  local source_valid=NO
  local revision_valid=NO
  local -a image_fields=()

  field_template='{{.Os}}
{{.Architecture}}
{{json .Config.User}}
{{json .Config.Entrypoint}}
{{json .Config.Cmd}}'
  config_template='{{json .Author}}
{{json .OsVersion}}
{{json .Variant}}
{{json .Config.User}}
{{json .Config.ExposedPorts}}
{{json .Config.Env}}
{{json .Config.Entrypoint}}
{{json .Config.Cmd}}
{{json .Config.Volumes}}
{{json .Config.WorkingDir}}
{{json .Config.StopSignal}}
{{json .Config.ArgsEscaped}}
{{json .Config.OnBuild}}
{{json .Config.Healthcheck}}
{{json .Config.Shell}}'
  label_template='{{range $key, $value := .Config.Labels}}{{if and (ne $key "org.opencontainers.image.source") (ne $key "org.opencontainers.image.revision")}}{{printf "%q=%s\n" $key (json $value)}}{{end}}{{end}}'

  docker image inspect --format "$field_template" "$image_id" > "$fields_path"
  mapfile -t image_fields < "$fields_path"
  [[ ${#image_fields[@]} -eq 5 ]] || return 1

  config_hash_line=$(docker image inspect --format "$config_template" "$image_id" | sha256sum)
  labels_hash_line=$(docker image inspect --format "$label_template" "$image_id" | sha256sum)
  config_hash=${config_hash_line%% *}
  labels_hash=${labels_hash_line%% *}
  source_label=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image_id")
  revision_label=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image_id")
  [[ "$source_label" == "$SOURCE_URL" ]] && source_valid=YES
  [[ "$revision_label" =~ ^[0-9a-f]{40}$ ]] && revision_valid=YES

  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "${image_fields[0]}" "${image_fields[1]}" "${image_fields[2]}" \
    "${image_fields[3]}" "${image_fields[4]}" "$config_hash" "$labels_hash" \
    "$source_valid" "$revision_valid" > "$destination"
}

expect_config_rejected() {
  local fixture_name=$1
  local fixture_path=$2
  if image_config_contract "$RUN_DIR/self-test/base.config" "$fixture_path"; then
    fail "self-test configuration checker accepted $fixture_name"
  fi
}

run_self_test() {
  local root
  local allowed_user='"65532"'
  local allowed_entrypoint='["pgbouncer"]'
  local allowed_cmd='["/etc/pgbouncer/pgbouncer.ini"]'
  local manifest_helper_output

  create_run_context self-test
  root="$RUN_DIR/self-test"
  command -v timeout >/dev/null 2>&1 || fail 'timeout utility is required for bounded proof helpers'
  mkdir -p "$root"
  write_filesystem_fixture "$root/base" base
  write_filesystem_fixture "$root/allowed" allowed
  write_filesystem_fixture "$root/removed" removed
  write_filesystem_fixture "$root/replaced" replaced
  write_filesystem_fixture "$root/extra" extra
  write_filesystem_fixture "$root/changed-mode" changed-mode
  write_filesystem_fixture "$root/changed-owner" changed-owner
  write_filesystem_fixture "$root/changed-link" changed-link
  write_filesystem_fixture "$root/changed-link-owner" changed-link-owner
  write_filesystem_fixture "$root/replaced-type" replaced-type
  manifest_helper_output=$(run_task4_helper self-test)
  [[ "$manifest_helper_output" == *'SELF_TEST_STATIC_ELF=PASS'* ]] || fail 'self-test did not accept a valid static ELF fixture'
  [[ "$manifest_helper_output" == *'SELF_TEST_DYNAMIC_ELF_REJECTED=YES'* ]] || fail 'self-test did not reject a dynamic ELF fixture'
  [[ "$manifest_helper_output" == *'SELF_TEST_OVERSIZE_REJECTED=YES'* ]] || fail 'self-test did not reject an oversize executable fixture'
  printf 'SELF_TEST_DYNAMIC_ELF_REJECTED=YES\nSELF_TEST_OVERSIZE_REJECTED=YES\n'

  if manifest_delta_check "$root/base.manifest" "$root/allowed.manifest"; then
    printf 'SELF_TEST_ALLOWED_DELTA=PASS\n'
  else
    fail 'self-test rejected the permitted one-probe filesystem delta'
  fi
  if manifest_delta_check "$root/base.manifest" "$root/removed.manifest"; then
    fail 'self-test filesystem checker accepted a removed base file'
  fi
  printf 'SELF_TEST_REMOVED_FILE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/replaced.manifest"; then
    fail 'self-test filesystem checker accepted a replaced base file'
  fi
  printf 'SELF_TEST_REPLACED_FILE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/extra.manifest"; then
    fail 'self-test filesystem checker accepted an extra file'
  fi
  printf 'SELF_TEST_EXTRA_FILE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/changed-mode.manifest"; then
    fail 'self-test filesystem checker accepted a base file mode change'
  fi
  printf 'SELF_TEST_MODE_CHANGE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/changed-owner.manifest"; then
    fail 'self-test filesystem checker accepted a base file ownership change'
  fi
  printf 'SELF_TEST_UID_GID_CHANGE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/changed-link.manifest"; then
    fail 'self-test filesystem checker accepted a symlink target change'
  fi
  printf 'SELF_TEST_SYMLINK_TARGET_CHANGE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/changed-link-owner.manifest"; then
    fail 'self-test filesystem checker accepted symlink ownership change'
  fi
  printf 'SELF_TEST_SYMLINK_OWNERSHIP_CHANGE_REJECTED=YES\n'
  if manifest_delta_check "$root/base.manifest" "$root/replaced-type.manifest"; then
    fail 'self-test filesystem checker accepted an object type change'
  fi
  printf 'SELF_TEST_OBJECT_TYPE_CHANGE_REJECTED=YES\n'

  write_config_fixture "$root/base.config" "$allowed_user" "$allowed_entrypoint" "$allowed_cmd" config-fingerprint labels-fingerprint NO NO
  write_config_fixture "$root/allowed.config" "$allowed_user" "$allowed_entrypoint" "$allowed_cmd" config-fingerprint labels-fingerprint YES YES
  if image_config_contract "$root/base.config" "$root/allowed.config"; then
    printf 'SELF_TEST_ALLOWED_CONFIG=PASS\n'
  else
    fail 'self-test rejected the permitted OCI label delta'
  fi
  write_config_fixture "$root/wrong-user.config" '"1000"' "$allowed_entrypoint" "$allowed_cmd" config-fingerprint labels-fingerprint YES YES
  expect_config_rejected 'wrong USER' "$root/wrong-user.config"
  printf 'SELF_TEST_WRONG_USER_REJECTED=YES\n'
  write_config_fixture "$root/wrong-entrypoint.config" "$allowed_user" '["/bin/sh"]' "$allowed_cmd" config-fingerprint labels-fingerprint YES YES
  expect_config_rejected 'wrong ENTRYPOINT' "$root/wrong-entrypoint.config"
  printf 'SELF_TEST_WRONG_ENTRYPOINT_REJECTED=YES\n'
  write_config_fixture "$root/wrong-cmd.config" "$allowed_user" "$allowed_entrypoint" '["/tmp/wrong.ini"]' config-fingerprint labels-fingerprint YES YES
  expect_config_rejected 'wrong CMD' "$root/wrong-cmd.config"
  printf 'SELF_TEST_WRONG_CMD_REJECTED=YES\n'
  write_config_fixture "$root/changed-env.config" "$allowed_user" "$allowed_entrypoint" "$allowed_cmd" config-fingerprint-with-env-change labels-fingerprint YES YES
  expect_config_rejected 'unexpected ENV/config change' "$root/changed-env.config"
  printf 'SELF_TEST_UNEXPECTED_ENV_REJECTED=YES\n'
  write_config_fixture "$root/changed-label.config" "$allowed_user" "$allowed_entrypoint" "$allowed_cmd" config-fingerprint changed-labels-fingerprint YES YES
  expect_config_rejected 'unexpected label change' "$root/changed-label.config"
  printf 'SELF_TEST_UNEXPECTED_LABEL_REJECTED=YES\n'
  write_config_fixture "$root/missing-source-label.config" "$allowed_user" "$allowed_entrypoint" "$allowed_cmd" config-fingerprint labels-fingerprint NO YES
  expect_config_rejected 'missing approved source label' "$root/missing-source-label.config"
  printf 'SELF_TEST_APPROVED_LABELS_REQUIRED=YES\nSELF_TEST=PASS\n'
}

run_static() {
  local image_reference=$1
  local base_name
  local candidate_name
  local base_platform
  local candidate_platform
  local helper_output
  local -a elf_report=()

  create_run_context static
  command -v timeout >/dev/null 2>&1 || fail 'timeout utility is required for bounded proof helpers'
  BASE_IMAGE_ID=$(resolve_frozen_base_image) || fail 'unable to resolve frozen base image from the exact digest'
  CANDIDATE_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$image_reference")
  [[ -n "$CANDIDATE_IMAGE_ID" ]] || fail "candidate image reference did not resolve: $image_reference"
  base_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$BASE_IMAGE_ID")
  candidate_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$CANDIDATE_IMAGE_ID")
  [[ "$base_platform" == linux/amd64 ]] || fail "frozen base platform must be linux/amd64, got: $base_platform"
  [[ "$candidate_platform" == linux/amd64 ]] || fail "candidate platform must be linux/amd64, got: $candidate_platform"

  capture_image_config_snapshot "$BASE_IMAGE_ID" "$RUN_DIR/base.config"
  capture_image_config_snapshot "$CANDIDATE_IMAGE_ID" "$RUN_DIR/candidate.config"
  if ! image_config_contract "$RUN_DIR/base.config" "$RUN_DIR/candidate.config"; then
    fail 'candidate image config differs from the frozen base contract'
  fi

  printf 'BASE_IMAGE_REFERENCE=%s\nBASE_IMAGE_ID=%s\n' "$BASE_IMAGE_REFERENCE" "$BASE_IMAGE_ID"
  printf 'CANDIDATE_REFERENCE=%s\nCANDIDATE_IMAGE_ID=%s\nCANDIDATE_PLATFORM=linux/amd64\n' "$image_reference" "$CANDIDATE_IMAGE_ID"
  printf 'FINAL_USER=65532\nFINAL_ENTRYPOINT=["pgbouncer"]\nFINAL_CMD=["/etc/pgbouncer/pgbouncer.ini"]\nUNEXPECTED_CONFIG_DELTA=NO\n'

  base_name="eventsales-r3-4-${RUN_ID}-base-static"
  candidate_name="eventsales-r3-4-${RUN_ID}-candidate-static"
  BASE_CONTAINER_ID=$(docker create --name "$base_name" --platform linux/amd64 "$BASE_IMAGE_ID")
  CANDIDATE_CONTAINER_ID=$(docker create --name "$candidate_name" --platform linux/amd64 "$CANDIDATE_IMAGE_ID")
  docker export --output "$RUN_DIR/base-rootfs.tar" "$BASE_CONTAINER_ID"
  docker export --output "$RUN_DIR/candidate-rootfs.tar" "$CANDIDATE_CONTAINER_ID"

  helper_output=$(run_task4_helper static)
  printf '%s\n' "$helper_output" > "$RUN_DIR/elf-report"
  mapfile -t elf_report < "$RUN_DIR/elf-report"
  [[ ${#elf_report[@]} -eq 4 ]] || fail 'ELF verifier returned an incomplete report'
  [[ "${elf_report[0]}" == PROBE_SIZE_BYTES=* ]] || fail 'ELF verifier did not report probe size'
  [[ "${elf_report[1]}" == PROBE_X86_64=YES ]] || fail 'probe is not x86-64'
  [[ "${elf_report[2]}" == PROBE_PT_INTERP=NONE ]] || fail 'probe has PT_INTERP'
  [[ "${elf_report[3]}" == PROBE_DT_NEEDED=NONE ]] || fail 'probe has DT_NEEDED'

  if ! manifest_delta_check "$RUN_DIR/base.manifest" "$RUN_DIR/candidate.manifest"; then
    printf 'BASE_FILESYSTEM_ENTRIES=%s\nCANDIDATE_FILESYSTEM_ENTRIES=%s\nREMOVED_BASE_ENTRIES=%s\nMODIFIED_BASE_ENTRIES=%s\nADDED_ENTRIES=%s\n' \
      "$FS_BASE_ENTRY_COUNT" "$FS_CANDIDATE_ENTRY_COUNT" "$FS_REMOVED_BASE_ENTRIES" "$FS_MODIFIED_BASE_ENTRIES" "$FS_ADDED_ENTRIES"
    fail 'candidate filesystem delta violates the one-probe contract'
  fi

  printf '%s\n' "BASE_FILESYSTEM_ENTRIES=$FS_BASE_ENTRY_COUNT" \
    "CANDIDATE_FILESYSTEM_ENTRIES=$FS_CANDIDATE_ENTRY_COUNT" \
    "REMOVED_BASE_ENTRIES=$FS_REMOVED_BASE_ENTRIES" \
    "MODIFIED_BASE_ENTRIES=$FS_MODIFIED_BASE_ENTRIES" \
    "ADDED_ENTRIES=$FS_ADDED_ENTRIES" \
    "ONLY_APPROVED_PROBE_ADDED=$ONLY_APPROVED_PROBE_ADDED" \
    "${elf_report[0]}" "${elf_report[1]}" "${elf_report[2]}" "${elf_report[3]}" \
    'STATIC_PROOF=PASS'
}

run_all() {
  local script_path="$SCRIPT_DIR/prove-image.sh"
  local build_log
  local line
  local built_image_id=''

  create_run_context all
  build_log="$RUN_DIR/build.log"
  bash "$script_path" self-test
  bash "$script_path" unit
  bash "$script_path" build | tee "$build_log"
  while IFS= read -r line; do
    case "$line" in
      BUILT_IMAGE_ID=*) built_image_id=${line#BUILT_IMAGE_ID=} ;;
    esac
  done < "$build_log"
  [[ -n "$built_image_id" ]] || fail 'build mode did not return an immutable image ID'
  bash "$script_path" static "$built_image_id"
  bash "$script_path" integration "$built_image_id"
  printf 'ALL_MODE=PASS\n'
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
    [[ -n "$1" ]] || usage
    run_static "$1"
    ;;
  self-test)
    (($# == 0)) || usage
    run_self_test
    ;;
  all)
    (($# == 0)) || usage
    run_all
    ;;
  *)
    printf 'unknown mode: %s\n' "$mode" >&2
    usage
    ;;
esac
