#!/usr/bin/env bash
# Shared helpers for WP-SOURCE-05 release candidate tooling (sourced, not executed).

CANONICAL_MAIN_REF="refs/remotes/origin/main"

ensure_canonical_main_ref() {
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "Git remote origin is not configured" >&2
    return 1
  fi

  if ! git fetch origin "+refs/heads/main:${CANONICAL_MAIN_REF}"; then
    echo "Failed to fetch canonical main from origin (full ref update required)" >&2
    return 1
  fi

  if ! git rev-parse --verify "${CANONICAL_MAIN_REF}" >/dev/null 2>&1; then
    echo "Canonical main ref missing after fetch: ${CANONICAL_MAIN_REF}" >&2
    return 1
  fi

  return 0
}

validate_suite_release_id() {
  local release_id="$1"
  php -r '
$id = $argv[1];
if (!preg_match(
    "/^(\d{4})\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])\.([1-9][0-9]*)$/",
    $id,
    $m
)) {
    fwrite(STDERR, "Invalid suite_release_id format: {$id}\n");
    exit(1);
}
$year = (int) $m[1];
$month = (int) $m[2];
$day = (int) $m[3];
if (!checkdate($month, $day, $year)) {
    fwrite(STDERR, "Invalid calendar date in suite_release_id: {$id}\n");
    exit(1);
}
' "$release_id"
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

assert_commit_on_canonical_main() {
  local commit_sha="$1"
  ensure_canonical_main_ref || return 1
  if ! git merge-base --is-ancestor "$commit_sha" "${CANONICAL_MAIN_REF}"; then
    echo "Commit $commit_sha is not reachable from canonical main" >&2
    return 1
  fi
  return 0
}

assert_source_on_canonical_main() {
  assert_commit_on_canonical_main "$1"
}

resolve_canonical_main_sha() {
  ensure_canonical_main_ref
  git rev-parse "${CANONICAL_MAIN_REF}"
}
