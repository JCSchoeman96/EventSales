#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export LC_ALL=C
umask 077

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
wrapper_source="$repo_root/deploy/vps/operator/agent-eventsales-v5-stage-proof-bundle"
sudoers_source="$repo_root/deploy/vps/operator/agent-eventsales-v5-stage-proof-bundle.sudoers"
data_plane_source="$repo_root/deploy/vps/data-plane"
source_commit='2e7b848c7d89c7c0a8e3b0f7f81cd9ef6c7a36e6'
old_commit='c9ce0f9239123a6e58f66fde0b5a1e60238bb107'
source_tree='3f2c4f6c521212cb81ef092198b0485f8285201e'
old_tree='bd818ee6d9ab617205d77fce8c8bfeeb90922aff'
readonly -a expected_files=(
  README.md
  compose.yaml
  pgbouncer-image/Dockerfile
  pgbouncer-image/eventsales_pgbouncer_healthcheck.rs
  pgbouncer-image/prove-image.sh
  scripts/bootstrap-postgres.sh
  scripts/generate-secrets.sh
  scripts/probe-pgbouncer.sh
  scripts/probe-postgres.sh
  scripts/probe-redis.sh
  scripts/provision-networks.sh
  scripts/render-runtime-config.sh
  templates/pgbouncer.ini.template
  templates/redis-users.acl.template
)
fixture_uid=$(/usr/bin/id -u)
fixture_gid=$(/usr/bin/id -g)
passes=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }

[[ -f "$wrapper_source" && ! -L "$wrapper_source" ]] || fail 'V5 stage wrapper source is missing'
[[ -f "$sudoers_source" && ! -L "$sudoers_source" ]] || fail 'V5 stage sudoers source is missing'
[[ -d "$data_plane_source" && ! -L "$data_plane_source" ]] || fail 'data-plane source directory is missing'

tmp_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/eventsales-v5-stage.XXXXXX")
fixture="$tmp_root/fixture"
root_fixture="$fixture/root"
home_fixture="$fixture/home/agentops"
candidate_parent="$home_fixture/.eventsales-v5-proof-bundle-$source_commit"
candidate="$candidate_parent/data-plane"
prod_root="$root_fixture/eventsales-prod"
stage_parent="$prod_root/staged"
c9ce_commit="$stage_parent/$old_commit"
c9ce_data="$c9ce_commit/data-plane"
target_commit="$stage_parent/$source_commit"
target_data="$target_commit/data-plane"
temp_stage="$stage_parent/.$source_commit-v5-proof-bundle-stage.tmp"
v4_marker="$prod_root/.v4-pgbouncer-redis-start-consumed"
v5_marker="$prod_root/.v5-proof-bundle-stage-consumed"
fixture_bin="$fixture/bin"
wrapper_fixture="$tmp_root/agent-eventsales-v5-stage-proof-bundle"
operation_log="$fixture/operations.log"
install_count_file="$fixture/install-count"
state_file="$fixture/state"
out="$fixture/stdout"
err="$fixture/stderr"

cleanup() {
  /usr/bin/chmod -R u+w "$tmp_root" 2>/dev/null || true
  /usr/bin/rm -rf -- "$tmp_root"
}
trap cleanup EXIT

mkdir -p "$fixture_bin"

cat >"$fixture_bin/id" <<ID
#!/usr/bin/env bash
set -euo pipefail
case "\${1-}" in
  -u) printf '%s\\n' '$fixture_uid' ;;
  -g) printf '%s\\n' '$fixture_gid' ;;
  *) exit 2 ;;
esac
ID

cat >"$fixture_bin/getent" <<GETENT
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1-}" == group && "\${2-}" == agentops ]] || exit 2
printf 'agentops:x:%s:\\n' '$fixture_gid'
GETENT

cat >"$fixture_bin/mkdir" <<MKDIR
#!/usr/bin/env bash
set -euo pipefail
for item in "\$@"; do :; done
printf 'MKDIR|%s\\n' "\${!#}" >>'$operation_log'
exec /usr/bin/mkdir "\$@"
MKDIR

cat >"$fixture_bin/install" <<INSTALL
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f '$install_count_file' ]] || read -r count <'$install_count_file'
count=\$((count + 1))
printf '%s\\n' "\$count" >'$install_count_file'
printf 'INSTALL|%s\\n' "\${!#}" >>'$operation_log'
fail_at=0
[[ ! -f '$state_file' ]] || fail_at=\$(/usr/bin/awk -F= '\$1 == "FAIL_INSTALL_AT" {print \$2; exit}' '$state_file')
if [[ "\$fail_at" == "\$count" ]]; then exit 73; fi
exec /usr/bin/install "\$@"
INSTALL

cat >"$fixture_bin/mv" <<MV
#!/usr/bin/env bash
set -euo pipefail
printf 'MV|%s\\n' "\${@: -2:1}" >>'$operation_log'
exec /usr/bin/mv "\$@"
MV

chmod 0755 "$fixture_bin/id" "$fixture_bin/getent" "$fixture_bin/mkdir" \
  "$fixture_bin/install" "$fixture_bin/mv"

render_test_wrapper() {
  /usr/bin/sed \
    -e "s|/root/eventsales-prod|$prod_root|g" \
    -e "s|/home/agentops|$home_fixture|g" \
    -e "s|readonly ROOT_UID='0'|readonly ROOT_UID='$fixture_uid'|" \
    -e "s|readonly ROOT_GID='0'|readonly ROOT_GID='$fixture_gid'|" \
    -e "s|require_root_directory /root protected|require_root_directory '$root_fixture' protected|" \
    -e "s|readonly SAFE_PATH='/usr/sbin:/usr/bin:/sbin:/bin'|readonly SAFE_PATH='$fixture_bin:/usr/sbin:/usr/bin:/sbin:/bin'|" \
    -e "s|readonly C9CE_DATA_PLANE_TREE='bd818ee6d9ab617205d77fce8c8bfeeb90922aff'|readonly C9CE_DATA_PLANE_TREE='$source_tree'|" \
    -e 's|8c1fa73a820a888fa2b08e3da946b2a3654d0dc4|43aad20cdf8da6169fa1972bf969c59b1ff1c758|g' \
    -e 's|9ad4e133d070576b453052c2fbe67f5eeea4fedd|f726bc7a7f56434ba019c155bd758c6cafb16d13|g' \
    -e 's/((EUID != ROOT_UID))/((TEST_EUID != ROOT_UID))/' \
    "$wrapper_source" >"$wrapper_fixture"
  chmod 0755 "$wrapper_fixture"
}

reset_fixture() {
  chmod -R u+w "$root_fixture" "$fixture/home" 2>/dev/null || true
  rm -rf -- "${root_fixture:?}" "${fixture:?}/home"
  rm -f -- "$operation_log" "$install_count_file" "$state_file" "$out" "$err"
  mkdir -p "$fixture_bin" "$candidate" "$c9ce_data" "$stage_parent" "$prod_root" \
    "$home_fixture" "$fixture/home" "$fixture/root"
  cp -R -- "$data_plane_source/." "$candidate/"
  cp -R -- "$data_plane_source/." "$c9ce_data/"
  chown -R "$fixture_uid:$fixture_gid" "$fixture"
  find "$candidate_parent" -type d -exec chmod 0700 {} +
  find "$candidate" -type f -exec chmod 0600 {} +
  chmod 0700 "$candidate_parent" "$candidate"
  mkdir -m 0700 "$v4_marker"
  for relative_path in "${expected_files[@]}"; do
    file="$c9ce_data/$relative_path"
    if [[ -x "$data_plane_source/$relative_path" ]]; then chmod 0555 "$file"; else chmod 0444 "$file"; fi
  done
  find "$c9ce_data" -type d -exec chown "$fixture_uid:$fixture_gid" {} +
  find "$c9ce_data" -type f -exec chown "$fixture_uid:$fixture_gid" {} +
  find "$c9ce_data" -type d -exec chmod 0555 {} +
  chmod 0555 "$c9ce_commit" "$c9ce_data"
  : >"$operation_log"
  printf '0\n' >"$install_count_file"
  printf 'FAIL_INSTALL_AT=0\n' >"$state_file"
  render_test_wrapper
}

run_wrapper() {
  local status=0
  env TEST_EUID="$fixture_uid" PATH="$fixture_bin:/usr/bin:/bin" \
    BASH_ENV='/caller/hostile-bash-env' ENV='/caller/env' CDPATH='/caller/cdpath' \
    "$wrapper_fixture" "$@" >"$out" 2>"$err" || status=$?
  return "$status"
}

expect_preflight_block() {
  local label=$1 marker_state=${2:-absent} target_state=${3:-absent} temp_state=${4:-absent} status=0
  run_wrapper || status=$?
  ((status != 0)) || fail "$label unexpectedly succeeded"
  grep -Fxq 'V5_PROOF_BUNDLE_STAGE=PREFLIGHT_BLOCKED' "$err" || {
    cat "$err" >&2
    fail "$label did not report PREFLIGHT_BLOCKED"
  }
  if [[ "$marker_state" == absent ]]; then
    [[ ! -e "$v5_marker" && ! -L "$v5_marker" ]] || fail "$label consumed the V5 marker before preflight completed"
  else
    [[ -e "$v5_marker" || -L "$v5_marker" ]] || fail "$label removed its pre-existing V5 marker"
  fi
  if [[ "$target_state" == absent ]]; then
    [[ ! -e "$target_commit" && ! -L "$target_commit" ]] || fail "$label created the final target before marker consumption"
  else
    [[ -e "$target_commit" || -L "$target_commit" ]] || fail "$label removed its pre-existing target"
  fi
  if [[ "$temp_state" == absent ]]; then
    [[ ! -e "$temp_stage" && ! -L "$temp_stage" ]] || fail "$label created temporary staging before marker consumption"
  else
    [[ -e "$temp_stage" || -L "$temp_stage" ]] || fail "$label removed its pre-existing temporary path"
  fi
}

file_digest() { git hash-object --no-filters -- "$1"; }

tree_fingerprint() {
  local root=$1
  find "$root" -mindepth 1 -printf '%y %m %u:%g %P\n' | sort
  while IFS= read -r -d '' path; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    printf '%s %s\n' "${path#"$root"/}" "$(file_digest "$path")"
  done < <(find "$root" -type f -print0)
}

assert_final_tree() {
  local relative_path expected_mode actual expected_blob
  local -a expected_paths=() actual_paths=()
  for relative_path in "${expected_files[@]}"; do
    expected_paths+=("$relative_path")
    expected_blob=$(file_digest "$data_plane_source/$relative_path")
    [[ "$(file_digest "$target_data/$relative_path")" == "$expected_blob" ]] || fail "final blob mismatch: $relative_path"
    if [[ -x "$data_plane_source/$relative_path" ]]; then expected_mode=555; else expected_mode=444; fi
    actual=$(stat -c '%u:%g:%a:%h' -- "$target_data/$relative_path")
    [[ "$actual" == "$fixture_uid:$fixture_gid:$expected_mode:1" ]] || fail "final file metadata mismatch: $relative_path"
  done
  while IFS= read -r -d '' path; do actual_paths+=("${path#"$target_data"/}"); done \
    < <(find "$target_data" -type f -print0)
  [[ "$(printf '%s\n' "${expected_paths[@]}" | sort)" == "$(printf '%s\n' "${actual_paths[@]}" | sort)" ]] \
    || fail 'final file inventory differs from the source manifest'
  for path in "$target_commit" "$target_data" "$target_data/pgbouncer-image" "$target_data/scripts" "$target_data/templates"; do
    [[ "$(stat -c '%u:%g:%a' -- "$path")" == "$fixture_uid:$fixture_gid:555" ]] || fail "final directory metadata mismatch: $path"
  done
}

grep -Fqx "readonly SOURCE_DATA_PLANE_TREE='$source_tree'" "$wrapper_source" || fail 'source subtree tree ID is not pinned'
grep -Fqx "readonly C9CE_DATA_PLANE_TREE='$old_tree'" "$wrapper_source" || fail 'c9ce subtree tree ID is not pinned'
grep -Fqx "  '100755 43aad20cdf8da6169fa1972bf969c59b1ff1c758 scripts/probe-pgbouncer.sh'" "$wrapper_source" \
  || fail 'current PgBouncer probe blob is not pinned'
grep -Fqx "  '100755 f726bc7a7f56434ba019c155bd758c6cafb16d13 scripts/probe-redis.sh'" "$wrapper_source" \
  || fail 'current Redis probe blob is not pinned'
grep -Fqx "  '100755 8c1fa73a820a888fa2b08e3da946b2a3654d0dc4 scripts/probe-pgbouncer.sh'" "$wrapper_source" \
  || fail 'c9ce PgBouncer probe blob is not pinned'
grep -Fqx "  '100755 9ad4e133d070576b453052c2fbe67f5eeea4fedd scripts/probe-redis.sh'" "$wrapper_source" \
  || fail 'c9ce Redis probe blob is not pinned'
for relative_path in "${expected_files[@]}"; do
  expected_blob=$(file_digest "$data_plane_source/$relative_path")
  grep -Fq "$expected_blob $relative_path'" "$wrapper_source" || fail "current manifest blob does not match $relative_path"
done
extract_manifest() {
  sed -n "/^readonly -a $1=(/,/^)/p" "$wrapper_source" \
    | sed -e '1d' -e '$d' -e "s/^  '//" -e "s/'$//"
}
declare -A source_by_path=() c9ce_by_path=()
while read -r git_mode expected_blob relative_path; do
  [[ -n "$relative_path" && -z "${source_by_path[$relative_path]+x}" ]] || fail 'source manifest has a duplicate path'
  source_by_path[$relative_path]="$git_mode $expected_blob"
done < <(extract_manifest SOURCE_MANIFEST)
while read -r git_mode expected_blob relative_path; do
  [[ -n "$relative_path" && -z "${c9ce_by_path[$relative_path]+x}" ]] || fail 'c9ce manifest has a duplicate path'
  c9ce_by_path[$relative_path]="$git_mode $expected_blob"
done < <(extract_manifest C9CE_MANIFEST)
[[ "${#source_by_path[@]}" -eq "${#expected_files[@]}" && "${#c9ce_by_path[@]}" -eq "${#expected_files[@]}" ]] \
  || fail 'a pinned manifest has a missing or unexpected path'
changed_manifest_paths=()
for relative_path in "${expected_files[@]}"; do
  [[ -n "${source_by_path[$relative_path]+x}" && -n "${c9ce_by_path[$relative_path]+x}" ]] \
    || fail "a pinned manifest omits $relative_path"
  read -r current_mode current_blob <<<"${source_by_path[$relative_path]}"
  read -r historical_mode historical_blob <<<"${c9ce_by_path[$relative_path]}"
  [[ "$current_mode" == "$historical_mode" ]] || fail "file mode changed unexpectedly: $relative_path"
  if [[ "$current_blob" != "$historical_blob" ]]; then changed_manifest_paths+=("$relative_path"); fi
done
[[ "${changed_manifest_paths[*]}" == 'scripts/probe-pgbouncer.sh scripts/probe-redis.sh' ]] \
  || fail 'the current and c9ce manifests differ outside the two approved probes'
pass 'source and c9ce tree IDs and both reviewed probe blob pairs are pinned'

expected_rule='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v5-stage-proof-bundle ""'
[[ "$(<"$sudoers_source")" == "$expected_rule" ]] || fail 'sudoers rule is not exact'
[[ $(wc -l <"$sudoers_source") -eq 1 ]] || fail 'sudoers contains extra lines'
! grep -Eiq 'ALL[[:space:]]*$|/bin/(ba)?sh|docker|\*|install|cp|chmod|chown|mv|rm' "$sudoers_source" \
  || fail 'sudoers grants broader authority'
/usr/sbin/visudo -cf "$sudoers_source" >/dev/null || fail 'visudo rejected the V5 sudoers rule'
pass 'sudoers grants exactly one zero-argument wrapper command'

render_test_wrapper
pass 'zero-argument interface fixture is prepared'

reset_fixture
status=0; run_wrapper forbidden-argument || status=$?
((status != 0)) || fail 'wrapper accepted an operator argument'
grep -Fxq 'V5_PROOF_BUNDLE_STAGE=PREFLIGHT_BLOCKED' "$err" || fail 'argument rejection was not a preflight block'
[[ ! -e "$v5_marker" ]] || fail 'argument rejection consumed the marker'
pass 'ZERO_ARGUMENT_INTERFACE=PASS; ARGUMENT_SUPPLIED=REJECTED'

reset_fixture
rm -rf -- "$candidate"
expect_preflight_block CANDIDATE_MISSING
pass 'CANDIDATE_MISSING=REJECTED; pre-marker failure leaves no marker or stage'

reset_fixture
rm -- "$candidate/scripts/probe-redis.sh"
ln -s "$data_plane_source/scripts/probe-redis.sh" "$candidate/scripts/probe-redis.sh"
expect_preflight_block CANDIDATE_SYMLINK
pass 'CANDIDATE_SYMLINK=REJECTED'

reset_fixture
printf 'extra\n' >"$candidate/extra.txt"
chmod 0600 "$candidate/extra.txt"
expect_preflight_block CANDIDATE_EXTRA_FILE
pass 'CANDIDATE_EXTRA_FILE=REJECTED'

reset_fixture
rm -- "$candidate/templates/redis-users.acl.template"
expect_preflight_block CANDIDATE_MISSING_FILE
pass 'CANDIDATE_MISSING_FILE=REJECTED'

reset_fixture
printf 'drift\n' >>"$candidate/compose.yaml"
expect_preflight_block CANDIDATE_BLOB_DRIFT
pass 'CANDIDATE_BLOB_DRIFT=REJECTED'

reset_fixture
mkfifo "$candidate/scripts/unexpected.pipe"
expect_preflight_block CANDIDATE_SPECIAL_FILE
pass 'CANDIDATE_SPECIAL_FILE=REJECTED'

reset_fixture
chmod 0640 "$candidate/scripts/probe-postgres.sh"
expect_preflight_block CANDIDATE_METADATA_DRIFT
pass 'CANDIDATE_METADATA_DRIFT=REJECTED'

reset_fixture
ln "$candidate/compose.yaml" "$candidate/scripts/unexpected-hardlink"
expect_preflight_block CANDIDATE_HARDLINK
pass 'CANDIDATE_HARDLINK=REJECTED'

reset_fixture
chmod 0755 "$candidate/scripts"
expect_preflight_block CANDIDATE_DIRECTORY_METADATA_DRIFT
pass 'CANDIDATE_DIRECTORY_METADATA_DRIFT=REJECTED'

reset_fixture
chmod 0644 "$c9ce_data/compose.yaml"
printf 'drift\n' >>"$c9ce_data/compose.yaml"
chmod 0444 "$c9ce_data/compose.yaml"
expect_preflight_block C9CE_BLOB_DRIFT
pass 'C9CE_BLOB_DRIFT=REJECTED'

reset_fixture
chmod 0755 "$c9ce_data/scripts"
printf 'extra\n' >"$c9ce_data/scripts/extra.sh"
chmod 0444 "$c9ce_data/scripts/extra.sh"
chmod 0555 "$c9ce_data/scripts"
expect_preflight_block C9CE_EXTRA_FILE
pass 'C9CE_EXTRA_FILE=REJECTED'

reset_fixture
chmod 0440 "$c9ce_data/compose.yaml"
expect_preflight_block C9CE_METADATA_DRIFT
pass 'C9CE_METADATA_DRIFT=REJECTED'

reset_fixture
chmod 0755 "$c9ce_data/scripts"
rm -- "$c9ce_data/scripts/probe-redis.sh"
ln -s "$data_plane_source/scripts/probe-redis.sh" "$c9ce_data/scripts/probe-redis.sh"
chmod 0555 "$c9ce_data/scripts"
expect_preflight_block C9CE_SYMLINK
pass 'C9CE_SYMLINK=REJECTED'

reset_fixture
chmod 0755 "$c9ce_data/scripts"
mkfifo "$c9ce_data/scripts/unexpected.pipe"
chmod 0555 "$c9ce_data/scripts"
expect_preflight_block C9CE_SPECIAL_FILE
pass 'C9CE_SPECIAL_FILE=REJECTED'

reset_fixture
rm -rf -- "$v4_marker"
expect_preflight_block V4_MARKER_MISSING
pass 'V4_MARKER_MISSING=REJECTED'

reset_fixture
rm -rf -- "$v4_marker"
: >"$v4_marker"
expect_preflight_block V4_MARKER_INVALID
pass 'V4_MARKER_INVALID=REJECTED'

reset_fixture
rm -rf -- "$v4_marker"
ln -s "$prod_root" "$v4_marker"
expect_preflight_block V4_MARKER_INVALID_SYMLINK
pass 'V4_MARKER_INVALID_SYMLINK=REJECTED'

reset_fixture
mkdir -m 0700 "$v5_marker"
expect_preflight_block V5_STAGE_MARKER_PRESENT present
pass 'V5_STAGE_MARKER_PRESENT=REJECTED'

reset_fixture
mkdir -m 0700 "$target_commit"
expect_preflight_block TARGET_PREEXISTS absent present
pass 'TARGET_PREEXISTS=REJECTED'

reset_fixture
mkdir -m 0700 "$temp_stage"
expect_preflight_block TEMP_STAGE_PREEXISTS absent absent present
pass 'TEMP_STAGE_PREEXISTS=REJECTED'

reset_fixture
candidate_before=$(tree_fingerprint "$candidate")
c9ce_before=$(tree_fingerprint "$c9ce_data")
status=0; run_wrapper || status=$?
((status == 0)) || { cat "$out" "$err" "$operation_log" >&2; fail 'valid bundle stage failed'; }
for expected in \
  'V5_PROOF_BUNDLE_STAGE=STAGED' \
  "SOURCE_COMMIT=$source_commit" \
  "TARGET=$target_data" \
  'TARGET_TREE_MATCH=YES' \
  'TARGET_METADATA=IMMUTABLE' \
  'C9CE_STAGE_UNCHANGED=YES' \
  'V4_MARKER=VALID' \
  'V5_STAGE_MARKER=CONSUMED' \
  'DOCKER_USED=NO' \
  'SERVICES_MUTATED=NO' \
  'V5_PROBES_EXECUTED=NO'; do
  grep -Fxq "$expected" "$out" || fail "successful wrapper output omitted $expected"
done
[[ -d "$v5_marker" && ! -L "$v5_marker" ]] || fail 'successful stage did not preserve the marker'
[[ "$(stat -c '%u:%g:%a' -- "$v5_marker")" == "$fixture_uid:$fixture_gid:700" ]] || fail 'stage marker metadata is incorrect'
assert_final_tree
pass 'VALID_STAGE=PASS; final inventory, blobs, and immutable metadata match the pinned manifest'

[[ "$(tree_fingerprint "$candidate")" == "$candidate_before" ]] || fail 'successful stage changed the candidate'
[[ "$(tree_fingerprint "$c9ce_data")" == "$c9ce_before" ]] || fail 'successful stage changed c9ce'
pass 'CANDIDATE_UNCHANGED_AFTER_SUCCESS=PASS; C9CE_UNCHANGED_AFTER_SUCCESS=PASS'

marker_line=$(grep -n -F "MKDIR|$v5_marker" "$operation_log" | cut -d: -f1 | head -n1)
temp_line=$(grep -n -F "MKDIR|$temp_stage" "$operation_log" | cut -d: -f1 | head -n1)
[[ -n "$marker_line" && -n "$temp_line" && "$marker_line" -lt "$temp_line" ]] \
  || fail 'V5 marker was not created before the first staging mutation'
pass 'MARKER_CONSUMED_BEFORE_FIRST_STAGE_MUTATION=PASS'

install_count=$(<"$install_count_file")
status=0; run_wrapper || status=$?
((status != 0)) || fail 'second invocation after success was accepted'
grep -Fxq 'V5_PROOF_BUNDLE_STAGE=PREFLIGHT_BLOCKED' "$err" || fail 'second invocation did not report preflight block'
[[ "$(<"$install_count_file")" == "$install_count" ]] || fail 'second invocation retried installation'
[[ -d "$target_commit" && -d "$v5_marker" ]] || fail 'second invocation altered successful stage state'
pass 'second invocation after success is rejected without retry'

reset_fixture
printf 'FAIL_INSTALL_AT=1\n' >"$state_file"
status=0; run_wrapper || status=$?
((status != 0)) || fail 'injected post-marker install failure unexpectedly succeeded'
grep -Fxq 'V5_PROOF_BUNDLE_STAGE=BLOCKED_AFTER_CONSUMPTION' "$err" || fail 'post-marker failure was not terminal'
[[ -d "$v5_marker" && -d "$temp_stage" && ! -e "$target_commit" ]] \
  || fail 'post-marker failure did not preserve partial staging state'
[[ "$(<"$install_count_file")" == 1 ]] || fail 'post-marker failure retried installation'
pass 'POSTMARK_FAILURE_IS_TERMINAL=PASS; partial state is preserved; no retry occurs'

status=0; run_wrapper || status=$?
((status != 0)) || fail 'second invocation after post-marker failure was accepted'
grep -Fxq 'V5_PROOF_BUNDLE_STAGE=PREFLIGHT_BLOCKED' "$err" || fail 'consumed authority was not rejected'
[[ "$(<"$install_count_file")" == 1 && -d "$temp_stage" ]] || fail 'post-marker retry changed partial state'
pass 'POSTMARK_FAILURE_DOES_NOT_RETRY=PASS; consumed authority cannot recover automatically'

if grep -Eiq '(^|[^[:alnum:]_])(docker|docker-compose|systemctl|service|psql|redis-cli|curl|wget|ssh|scp|rsync)([[:space:]]|$)' "$wrapper_source"; then
  fail 'wrapper references a forbidden production tool'
fi
! grep -Fq '/root/eventsales-prod/secrets-v1' "$wrapper_source" || fail 'wrapper references the production secret directory'
! grep -Eiq '(^|[[:space:]])(bash|sh)[[:space:]].*probe-(postgres|pgbouncer|redis)\.sh' "$wrapper_source" \
  || fail 'wrapper executes a V5 probe'
pass 'DOCKER_NOT_CALLED=PASS; PROBES_NOT_EXECUTED=PASS; SECRETS_NOT_ACCESSED=PASS'

printf 'RESULT=PASS\nTESTS=%s\n' "$passes"
