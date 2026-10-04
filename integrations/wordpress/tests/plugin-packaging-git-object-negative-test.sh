#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/wordpress_plugin_packaging_git_object.sh
source "$ROOT/scripts/lib/wordpress_plugin_packaging_git_object.sh"

failures=0

assert_rejects() {
  local label="$1"
  local mode="$2"
  local objtype="$3"
  local path="$4"
  if validate_wordpress_packaging_git_object "$mode" "$objtype" "$path" >/dev/null 2>&1; then
    echo "FAIL: expected rejection for ${label}" >&2
    failures=$((failures + 1))
  fi
}

assert_accepts() {
  local label="$1"
  local mode="$2"
  local objtype="$3"
  local path="$4"
  if ! validate_wordpress_packaging_git_object "$mode" "$objtype" "$path" >/dev/null 2>&1; then
    echo "FAIL: expected acceptance for ${label}" >&2
    failures=$((failures + 1))
  fi
}

assert_rejects "symlink mode 120000" 120000 blob "integrations/wordpress/eventsales-tickera-catalog-feed/evil.php"
assert_rejects "gitlink submodule" 160000 commit "integrations/wordpress/eventsales-tickera-catalog-feed/submodule"
assert_rejects "tree object" 040000 tree "integrations/wordpress/eventsales-tickera-catalog-feed"
assert_rejects "unexpected mode 100664" 100664 blob "integrations/wordpress/eventsales-tickera-catalog-feed/file.php"

assert_accepts "regular file 100644" 100644 blob "integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php"
assert_accepts "executable 100755" 100755 blob "integrations/wordpress/eventsales-tickera-catalog-feed/bin.php"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.email "packaging-test@eventsales.test"
git -C "$TMP" config user.name "EventSales Packaging Test"

mkdir -p "$TMP/integrations/wordpress/eventsales-tickera-catalog-feed"
printf '%s\n' '<?php // fixture' >"$TMP/integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php"
ln -s "eventsales-tickera-catalog-feed.php" "$TMP/integrations/wordpress/eventsales-tickera-catalog-feed/symlink-fixture.php"
git -C "$TMP" add integrations/wordpress/eventsales-tickera-catalog-feed
git -C "$TMP" commit -q -m "symlink fixture"

tree="$(git -C "$TMP" rev-parse HEAD^{tree})"
while read -r mode objtype _object git_path; do
  [[ -z "$git_path" ]] && continue
  case "$git_path" in
    */symlink-fixture.php)
      if validate_wordpress_packaging_git_object "$mode" "$objtype" "$git_path" >/dev/null 2>&1; then
        echo "FAIL: real git symlink fixture should be rejected (mode=${mode})" >&2
        failures=$((failures + 1))
      fi
      ;;
  esac
done < <(git -C "$TMP" ls-tree -r "$tree" integrations/wordpress/eventsales-tickera-catalog-feed)

if [[ "$failures" -ne 0 ]]; then
  echo "plugin-packaging-git-object-negative-test: ${failures} failure(s)" >&2
  exit 1
fi

echo "plugin-packaging-git-object-negative-test: passed"
