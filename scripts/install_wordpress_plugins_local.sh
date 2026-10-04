#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOCKED_HOME="http://localhost:10059"

if [[ -z "${EVENTSALES_WP_ROOT:-}" ]]; then
  echo "EVENTSALES_WP_ROOT is required" >&2
  exit 1
fi

if [[ "${EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE:-}" != "1" ]]; then
  echo "Set EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE=1 to acknowledge plugin replacement" >&2
  exit 1
fi

if ! command -v wp >/dev/null 2>&1; then
  echo "wp (WP-CLI) is required" >&2
  exit 1
fi

normalize_url() {
  local url="$1"
  url="${url%/}"
  echo "$url"
}

WP_HOME="$(normalize_url "$(wp option get home --path="$EVENTSALES_WP_ROOT")")"
WP_SITEURL="$(normalize_url "$(wp option get siteurl --path="$EVENTSALES_WP_ROOT")")"

if [[ "$WP_HOME" != "$LOCKED_HOME" || "$WP_SITEURL" != "$LOCKED_HOME" ]]; then
  echo "Refusing install: WordPress URLs must be $LOCKED_HOME (got home=$WP_HOME siteurl=$WP_SITEURL)" >&2
  exit 1
fi

DIST_DIR="${1:-}"
if [[ -z "$DIST_DIR" ]]; then
  COMMIT="$(git rev-parse HEAD)"
  DIST_DIR="$ROOT/tmp/wordpress-plugin-dist/$COMMIT"
fi

if [[ ! -d "$DIST_DIR" ]]; then
  echo "Distribution directory not found: $DIST_DIR" >&2
  exit 1
fi

bash "$ROOT/scripts/verify_wordpress_plugin_packages.sh" "$DIST_DIR"

ACTIVATION_ORDER=(
  eventsales-tickera-catalog-feed
  eventsales-woo-order-index-feed
  eventsales-woo-order-line-identity
  eventsales-integration-health
)

for slug in "${ACTIVATION_ORDER[@]}"; do
  zip_file="$(find "$DIST_DIR" -maxdepth 1 -name "${slug}-*.zip" | head -n 1)"
  if [[ -z "$zip_file" ]]; then
    echo "Missing archive for $slug in $DIST_DIR" >&2
    exit 1
  fi
  wp plugin install "$zip_file" --force --path="$EVENTSALES_WP_ROOT"
  wp plugin activate "$slug" --path="$EVENTSALES_WP_ROOT"
  status="$(wp plugin get "$slug" --field=status --path="$EVENTSALES_WP_ROOT")"
  if [[ "$status" != "active" ]]; then
    echo "Plugin $slug is not active after install (status=$status)" >&2
    exit 1
  fi
done

echo "Local ZIP install completed from $DIST_DIR"
echo "All four EventSales plugins are active."
echo "Run Site Health checks via WP-CLI or wp-admin Tools -> Site Health"
