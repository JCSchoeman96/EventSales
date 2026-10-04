#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash "$ROOT/integrations/wordpress/tests/plugin-packaging-git-object-negative-test.sh"
php "$ROOT/integrations/wordpress/tests/plugin-distribution-test.php" --source
bash "$ROOT/scripts/build_wordpress_plugins.sh" --ref HEAD
COMMIT="$(git rev-parse HEAD)"
bash "$ROOT/scripts/verify_wordpress_plugin_packages.sh" "$ROOT/tmp/wordpress-plugin-dist/$COMMIT"

echo "WordPress plugin distribution CI gate passed."
