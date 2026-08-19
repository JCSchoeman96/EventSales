#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCRIPT="${REPO_ROOT}/scripts/sync_with_origin_main.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  grep -Fq -- "$needle" <<<"$haystack" || fail "missing output: $needle"
}

assert_absent() {
  local haystack="$1"
  local needle="$2"

  if grep -Fq -- "$needle" <<<"$haystack"; then
    fail "unexpected output: $needle"
  fi
}

make_repo() {
  local name="$1"

  git init -q --bare "${tmp_dir}/${name}-remote.git"
  git init -q -b main "${tmp_dir}/${name}-seed"
  git -C "${tmp_dir}/${name}-seed" config user.name Test
  git -C "${tmp_dir}/${name}-seed" config user.email test@example.invalid
  git -C "${tmp_dir}/${name}-seed" commit --allow-empty -qm initial
  git -C "${tmp_dir}/${name}-seed" remote add origin "${tmp_dir}/${name}-remote.git"
  git -C "${tmp_dir}/${name}-seed" push -q -u origin main
  git -C "${tmp_dir}/${name}-remote.git" symbolic-ref HEAD refs/heads/main
  git clone -q --branch main "${tmp_dir}/${name}-remote.git" "${tmp_dir}/${name}-work"
  git -C "${tmp_dir}/${name}-work" config user.name Test
  git -C "${tmp_dir}/${name}-work" config user.email test@example.invalid
}

advance_remote() {
  local name="$1"

  git -C "${tmp_dir}/${name}-seed" commit --allow-empty -qm "remote update"
  git -C "${tmp_dir}/${name}-seed" push -q origin main
}

run_sync() {
  local work="$1"
  local mode="${2:---sync}"

  set +e
  SYNC_OUTPUT="$(cd "$work" && bash "$SCRIPT" "$mode" 2>&1)"
  SYNC_STATUS=$?
  set -e
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

make_repo behind
advance_remote behind
behind_remote_head="$(git -C "${tmp_dir}/behind-seed" rev-parse main)"
run_sync "${tmp_dir}/behind-work"
[[ "$SYNC_STATUS" -eq 0 ]] || fail "behind main did not sync"
[[ "$(git -C "${tmp_dir}/behind-work" rev-parse HEAD)" == "$behind_remote_head" ]] ||
  fail "behind main did not fast-forward to origin/main"
assert_contains "$SYNC_OUTPUT" '|> action: git merge --ff-only origin/main'

make_repo current
current_head="$(git -C "${tmp_dir}/current-work" rev-parse HEAD)"
run_sync "${tmp_dir}/current-work"
[[ "$SYNC_STATUS" -eq 0 ]] || fail "current main did not remain a no-op"
[[ "$(git -C "${tmp_dir}/current-work" rev-parse HEAD)" == "$current_head" ]] ||
  fail "current main changed unexpectedly"
assert_contains "$SYNC_OUTPUT" '|> action: none'

make_repo ahead
git -C "${tmp_dir}/ahead-work" commit --allow-empty -qm "local update"
ahead_head="$(git -C "${tmp_dir}/ahead-work" rev-parse HEAD)"
run_sync "${tmp_dir}/ahead-work"
[[ "$SYNC_STATUS" -ne 0 ]] || fail "ahead main unexpectedly synced"
[[ "$(git -C "${tmp_dir}/ahead-work" rev-parse HEAD)" == "$ahead_head" ]] ||
  fail "ahead main changed unexpectedly"
assert_contains "$SYNC_OUTPUT" 'main is ahead of or diverged from origin/main'

make_repo diverged
git -C "${tmp_dir}/diverged-work" commit --allow-empty -qm "local update"
git -C "${tmp_dir}/diverged-seed" commit --allow-empty -qm "remote update"
git -C "${tmp_dir}/diverged-seed" push -q origin main
diverged_head="$(git -C "${tmp_dir}/diverged-work" rev-parse HEAD)"
run_sync "${tmp_dir}/diverged-work"
[[ "$SYNC_STATUS" -ne 0 ]] || fail "diverged main unexpectedly synced"
[[ "$(git -C "${tmp_dir}/diverged-work" rev-parse HEAD)" == "$diverged_head" ]] ||
  fail "diverged main changed unexpectedly"
assert_contains "$SYNC_OUTPUT" 'main is ahead of or diverged from origin/main'

make_repo dirty
touch "${tmp_dir}/dirty-work/untracked.txt"
dirty_head="$(git -C "${tmp_dir}/dirty-work" rev-parse HEAD)"
run_sync "${tmp_dir}/dirty-work"
[[ "$SYNC_STATUS" -ne 0 ]] || fail "dirty main unexpectedly synced"
[[ "$(git -C "${tmp_dir}/dirty-work" rev-parse HEAD)" == "$dirty_head" ]] ||
  fail "dirty main changed unexpectedly"
assert_contains "$SYNC_OUTPUT" 'working tree has local changes'

make_repo conflict
printf 'local\n' >"${tmp_dir}/conflict-work/conflict.txt"
git -C "${tmp_dir}/conflict-work" add conflict.txt
git -C "${tmp_dir}/conflict-work" commit -qm "local conflict"
printf 'remote\n' >"${tmp_dir}/conflict-seed/conflict.txt"
git -C "${tmp_dir}/conflict-seed" add conflict.txt
git -C "${tmp_dir}/conflict-seed" commit -qm "remote conflict"
git -C "${tmp_dir}/conflict-seed" push -q origin main
git -C "${tmp_dir}/conflict-work" fetch -q origin
set +e
git -C "${tmp_dir}/conflict-work" merge --no-edit origin/main >/dev/null 2>&1
merge_status=$?
set -e
[[ "$merge_status" -ne 0 ]] || fail "conflict fixture did not create a merge conflict"
run_sync "${tmp_dir}/conflict-work" --check
[[ "$SYNC_STATUS" -ne 0 ]] || fail "conflicted main unexpectedly passed checks"
assert_contains "$SYNC_OUTPUT" 'rebases and merges'
assert_absent "$SYNC_OUTPUT" 'rebases and pulls'

printf 'sync_with_origin_main tests passed\n'
