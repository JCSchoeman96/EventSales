#!/usr/bin/env bash
# Shared helpers for WP-SOURCE-05 release candidate tooling (sourced, not executed).

ensure_canonical_main_ref() {
  git fetch origin main --depth=1 2>/dev/null || git fetch origin main 2>/dev/null || true
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    return 0
  fi
  if git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
    return 0
  fi
  if git rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
    git update-ref refs/remotes/origin/main FETCH_HEAD
    return 0
  fi
  echo "Unable to resolve origin/main after fetch" >&2
  return 1
}

validate_suite_release_id() {
  local release_id="$1"
  if [[ ! "$release_id" =~ ^[0-9]{4}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])\.[1-9][0-9]*$ ]]; then
    echo "Invalid suite_release_id: $release_id" >&2
    echo "Expected YYYY.MM.DD.N with valid calendar month/day and positive N" >&2
    return 1
  fi
  return 0
}

suggested_tag_for_release_id() {
  local release_id="$1"
  printf 'eventsales-wp-%s' "$release_id"
}

validate_source_commit_sha() {
  local sha="$1"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "source_commit must be 40-character lowercase hex: $sha" >&2
    return 1
  fi
  if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    echo "Git commit object not found: $sha" >&2
    return 1
  fi
  return 0
}

assert_source_on_canonical_main() {
  local source_sha="$1"
  ensure_canonical_main_ref || return 1
  if ! git merge-base --is-ancestor "$source_sha" origin/main; then
    echo "source_commit $source_sha is not reachable from origin/main" >&2
    return 1
  fi
  return 0
}

resolve_canonical_main_sha() {
  ensure_canonical_main_ref
  git rev-parse origin/main
}
