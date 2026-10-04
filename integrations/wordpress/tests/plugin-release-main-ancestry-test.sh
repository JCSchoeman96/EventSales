#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/wordpress_plugin_release_common.sh
source "$ROOT/scripts/lib/wordpress_plugin_release_common.sh"

fail() {
  echo "plugin-release-main-ancestry-test: $1" >&2
  exit 1
}

WORK="$(mktemp -d)"
BARE="$WORK/upstream.git"
BUILD="$WORK/build"
CLONE="$WORK/shallow-clone"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME="EventSales Test"
export GIT_AUTHOR_EMAIL="eventsales-test@example.invalid"
export GIT_COMMITTER_NAME="EventSales Test"
export GIT_COMMITTER_EMAIL="eventsales-test@example.invalid"

git init --bare "$BARE" >/dev/null
git -C "$BARE" symbolic-ref HEAD refs/heads/main

git init "$BUILD" >/dev/null
git -C "$BUILD" remote add origin "$BARE"
echo v1 >"$BUILD/content.txt"
git -C "$BUILD" add content.txt
git -C "$BUILD" commit -m "commit-1" >/dev/null
echo v2 >>"$BUILD/content.txt"
git -C "$BUILD" commit -am "commit-2" >/dev/null
echo v3 >>"$BUILD/content.txt"
git -C "$BUILD" commit -am "commit-3" >/dev/null
git -C "$BUILD" branch -M main
COMMIT2="$(git -C "$BUILD" rev-parse HEAD~1)"
git -C "$BUILD" push -u origin main >/dev/null

git clone --depth 1 --branch main "$BARE" "$CLONE" >/dev/null
git -C "$CLONE" remote set-url origin "$BARE"

(
  cd "$CLONE"
  if ! assert_commit_on_canonical_main "$COMMIT2"; then
    fail "older main ancestor must pass after shallow unshallow/deepen"
  fi
  if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
    fail "repository should not remain shallow after canonical main ensure"
  fi
)

(
  cd "$CLONE"
  git remote set-url origin "http://127.0.0.1:9/invalid-remote"
  if ensure_canonical_main_ref >/dev/null 2>&1; then
    fail "failed fetch must not succeed with stale canonical main ref"
  fi
)

(
  cd "$CLONE"
  git remote set-url origin "$BARE"
  if ! ensure_canonical_main_ref; then
    fail "ensure should succeed again after restoring origin"
  fi
)

echo "plugin-release-main-ancestry-test: passed"
