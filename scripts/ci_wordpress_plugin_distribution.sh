#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/wordpress_plugin_release_common.sh
source "$ROOT/scripts/lib/wordpress_plugin_release_common.sh"

bash "$ROOT/integrations/wordpress/tests/plugin-packaging-git-object-negative-test.sh"
php "$ROOT/integrations/wordpress/tests/plugin-distribution-test.php" --source
bash "$ROOT/scripts/build_wordpress_plugins.sh" --ref HEAD
COMMIT="$(git rev-parse HEAD)"
bash "$ROOT/scripts/verify_wordpress_plugin_packages.sh" "$ROOT/tmp/wordpress-plugin-dist/$COMMIT"
bash "$ROOT/scripts/check_wordpress_plugin_distribution_reproducibility.sh" --ref HEAD
python3 "$ROOT/integrations/wordpress/tests/plugin-deterministic-zip-order-test.py"
bash "$ROOT/integrations/wordpress/tests/plugin-release-candidate-negative-test.sh"
php "$ROOT/integrations/wordpress/tests/plugin-release-transition-test.php"
ensure_canonical_main_ref
MAIN_SHA="$(git rev-parse origin/main)"
bash "$ROOT/scripts/build_wordpress_plugin_release_candidate.sh" --ref "$MAIN_SHA" --release-id "2026.10.04.1"
CANDIDATE="$ROOT/tmp/wordpress-plugin-release/$MAIN_SHA/2026.10.04.1"
php "$ROOT/integrations/wordpress/tests/plugin-release-candidate-test.php" --candidate "$CANDIDATE"
bash "$ROOT/scripts/verify_wordpress_plugin_release_candidate.sh" "$CANDIDATE"

echo "WordPress plugin distribution CI gate passed."
