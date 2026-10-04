#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/verify_wordpress_plugin_packages.sh <dist-directory>" >&2
  exit 1
fi

DIST_DIR="$(cd "$1" && pwd)"

php "$ROOT/integrations/wordpress/tests/plugin-distribution-test.php" --source
php "$ROOT/integrations/wordpress/tests/plugin-distribution-test.php" --dist "$DIST_DIR"

VERIFY_STAGING="$(mktemp -d)"
trap 'rm -rf "$VERIFY_STAGING"' EXIT

mapfile -t ARCHIVES < <(find "$DIST_DIR" -maxdepth 1 -name '*.zip' | sort)
if [[ "${#ARCHIVES[@]}" -ne 4 ]]; then
  echo "Expected four ZIP archives in $DIST_DIR" >&2
  exit 1
fi

for archive in "${ARCHIVES[@]}"; do
  unzip -q "$archive" -d "$VERIFY_STAGING/extract"
  while IFS= read -r php_file; do
    if ! php -l "$php_file" >/dev/null; then
      echo "php -l failed for packaged file: $php_file" >&2
      php -l "$php_file" >&2 || true
      exit 1
    fi
  done < <(find "$VERIFY_STAGING/extract" -type f -name '*.php')
  rm -rf "$VERIFY_STAGING/extract"
done

echo "Package verification passed for $DIST_DIR"
