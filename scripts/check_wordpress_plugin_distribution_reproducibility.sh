#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REF="HEAD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      REF="${2:?--ref requires a value}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

COMMIT="$(git rev-parse "${REF}^{commit}")"
OUT_A="$(mktemp -d)"
OUT_B="$(mktemp -d)"
trap 'rm -rf "$OUT_A" "$OUT_B"' EXIT

WP_BUILD_OUT_DIR="$OUT_A" bash "$ROOT/scripts/build_wordpress_plugins.sh" --ref "$COMMIT"
WP_BUILD_OUT_DIR="$OUT_B" bash "$ROOT/scripts/build_wordpress_plugins.sh" --ref "$COMMIT"

php "$ROOT/integrations/wordpress/tests/plugin-distribution-reproducibility-test.php" "$OUT_A" "$OUT_B"

echo "WordPress plugin distribution reproducibility check passed."
