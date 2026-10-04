#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/scripts/build_wordpress_plugin_release_candidate.sh"
HEAD_SHA="$(git rev-parse HEAD)"

fail() {
  echo "Expected failure: $1" >&2
  exit 1
}

if bash "$BUILD" --ref 'not-a-sha' --release-id '2026.10.04.1' >/dev/null 2>&1; then
  fail "malformed SHA"
fi

if bash "$BUILD" --ref "$(printf '%040d' 0)" --release-id '2026.10.04.1' >/dev/null 2>&1; then
  fail "unknown SHA"
fi

TREE_SHA="$(git rev-parse HEAD^{tree})"
if bash "$BUILD" --ref "$TREE_SHA" --release-id '2026.10.04.1' >/dev/null 2>&1; then
  fail "tree object instead of commit"
fi

if bash "$BUILD" --ref "$HEAD_SHA" --release-id 'bad-id' >/dev/null 2>&1; then
  fail "invalid release ID"
fi

EMPTY_TREE="$(git mktree </dev/null)"
ORPHAN_SHA="$(
  GIT_AUTHOR_NAME="EventSales Test" \
  GIT_AUTHOR_EMAIL="eventsales-test@example.invalid" \
  GIT_COMMITTER_NAME="EventSales Test" \
  GIT_COMMITTER_EMAIL="eventsales-test@example.invalid" \
  git commit-tree "$EMPTY_TREE" -m "wp-release-candidate negative test"
)"
if git merge-base --is-ancestor "$ORPHAN_SHA" origin/main 2>/dev/null; then
  echo "orphan commit unexpectedly on main history" >&2
  exit 1
fi
if bash "$BUILD" --ref "$ORPHAN_SHA" --release-id '2026.10.04.1' >/dev/null 2>&1; then
  fail "commit not reachable from origin/main"
fi

echo "plugin-release-candidate-negative-test: passed"
