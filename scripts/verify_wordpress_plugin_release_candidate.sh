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

RELEASE_MANIFEST="$CANDIDATE_DIR/release-manifest.json"
if [[ ! -f "$RELEASE_MANIFEST" ]]; then
  echo "Missing release-manifest.json" >&2
  exit 1
fi

SOURCE_SHA="$(php -r 'echo json_decode(file_get_contents($argv[1]), true)["source_commit"];' "$RELEASE_MANIFEST")"
validate_source_commit_sha "$SOURCE_SHA"
assert_source_on_canonical_main "$SOURCE_SHA"

DIST_MANIFEST="$CANDIDATE_DIR/manifest.json"
DIST_COMMIT="$(php -r 'echo json_decode(file_get_contents($argv[1]), true)["source_commit"];' "$DIST_MANIFEST")"
if [[ "$DIST_COMMIT" != "$SOURCE_SHA" ]]; then
  echo "release manifest source_commit does not match distribution manifest" >&2
  exit 1
fi

RELEASE_SUMS="$CANDIDATE_DIR/RELEASE_SHA256SUMS"
if [[ ! -f "$RELEASE_SUMS" ]]; then
  echo "Missing RELEASE_SHA256SUMS" >&2
  exit 1
fi

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
