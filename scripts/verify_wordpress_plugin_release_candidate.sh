#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/wordpress_plugin_release_common.sh
source "$ROOT/scripts/lib/wordpress_plugin_release_common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/verify_wordpress_plugin_release_candidate.sh <candidate-directory>" >&2
  exit 1
fi

CANDIDATE_DIR="$(cd "$1" && pwd)"

php "$ROOT/integrations/wordpress/tests/plugin-release-candidate-test.php" --candidate "$CANDIDATE_DIR"

bash "$ROOT/scripts/verify_wordpress_plugin_packages.sh" "$CANDIDATE_DIR"

php "$ROOT/integrations/wordpress/tests/release-candidate-verify.php" --candidate "$CANDIDATE_DIR"

RELEASE_MANIFEST="$CANDIDATE_DIR/release-manifest.json"
SOURCE_SHA="$(php -r 'echo strtolower(json_decode(file_get_contents($argv[1]), true)["source_commit"]);' "$RELEASE_MANIFEST")"
CANONICAL_MAIN_AT_BUILD="$(php -r 'echo strtolower(json_decode(file_get_contents($argv[1]), true)["canonical_main_at_build"]);' "$RELEASE_MANIFEST")"

validate_source_commit_sha "$SOURCE_SHA"
validate_source_commit_sha "$CANONICAL_MAIN_AT_BUILD"
assert_source_on_canonical_main "$SOURCE_SHA"
assert_commit_on_canonical_main "$CANONICAL_MAIN_AT_BUILD"

if ! git merge-base --is-ancestor "$SOURCE_SHA" "$CANONICAL_MAIN_AT_BUILD"; then
  echo "source_commit must be an ancestor of canonical_main_at_build recorded in release manifest" >&2
  exit 1
fi

RELEASE_SUMS="$CANDIDATE_DIR/RELEASE_SHA256SUMS"
(
  cd "$CANDIDATE_DIR"
  while read -r hash file; do
    [[ -z "$hash" ]] && continue
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" != "$hash" ]]; then
      echo "RELEASE_SHA256SUMS mismatch for $file" >&2
      exit 1
    fi
  done < <(awk '{print $1, $2}' "$RELEASE_SUMS")
)

echo "Release candidate verification passed for $CANDIDATE_DIR"
