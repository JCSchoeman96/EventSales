#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOCKED_HOME="http://localhost:10059"

if [[ -z "${EVENTSALES_WP_ROOT:-}" ]]; then
  echo "EVENTSALES_WP_ROOT is required" >&2
  exit 1
fi

if [[ ! -d "$EVENTSALES_WP_ROOT" ]]; then
  echo "EVENTSALES_WP_ROOT must be an existing WordPress directory" >&2
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

declare -A ZIP_BY_SLUG=()
for slug in "${ACTIVATION_ORDER[@]}"; do
  mapfile -t archives < <(find "$DIST_DIR" -maxdepth 1 -type f -name "${slug}-*.zip" -print)
  if [[ "${#archives[@]}" -ne 1 ]]; then
    echo "Expected one verified archive for $slug in $DIST_DIR" >&2
    exit 1
  fi
  ZIP_BY_SLUG["$slug"]="${archives[0]}"
done

if ! WP_PLUGIN_DIR="$(wp eval 'echo WP_PLUGIN_DIR;' --path="$EVENTSALES_WP_ROOT")"; then
  echo "Refusing install: could not resolve WP_PLUGIN_DIR from WordPress" >&2
  exit 1
fi
while [[ "$WP_PLUGIN_DIR" != "/" && "$WP_PLUGIN_DIR" == */ ]]; do
  WP_PLUGIN_DIR="${WP_PLUGIN_DIR%/}"
done

if [[ -z "$WP_PLUGIN_DIR" || "$WP_PLUGIN_DIR" != /* ]]; then
  echo "Refusing install: WP_PLUGIN_DIR must resolve to an absolute path" >&2
  exit 1
fi
if [[ -L "$WP_PLUGIN_DIR" ]]; then
  echo "Refusing install: plugin root is a symlink (reason=plugin_root_symlink)" >&2
  exit 1
fi
if [[ ! -d "$WP_PLUGIN_DIR" ]]; then
  echo "Refusing install: WP_PLUGIN_DIR must be an existing directory (reason=plugin_root_other)" >&2
  exit 1
fi
if ! PLUGIN_ROOT_REAL="$(realpath -e -- "$WP_PLUGIN_DIR")"; then
  echo "Refusing install: could not resolve canonical WP_PLUGIN_DIR (reason=plugin_root_other)" >&2
  exit 1
fi
if [[ "$PLUGIN_ROOT_REAL" == "/" ]]; then
  echo "Refusing install: WP_PLUGIN_DIR cannot be the filesystem root (reason=plugin_root_other)" >&2
  exit 1
fi
if ! command -v findmnt >/dev/null 2>&1; then
  echo "Refusing install: mount boundary inspection is unavailable (reason=plugin_root_other)" >&2
  exit 1
fi
if ! PLUGIN_ROOT_MOUNT_ID="$(findmnt -n -o ID -T "$PLUGIN_ROOT_REAL" 2>/dev/null)" || [[ -z "$PLUGIN_ROOT_MOUNT_ID" ]]; then
  echo "Refusing install: could not inspect WP_PLUGIN_DIR mount (reason=plugin_root_other)" >&2
  exit 1
fi

preflight_destination() {
  local slug="$1"
  local destination="$WP_PLUGIN_DIR/$slug"
  local destination_real destination_mount_id nested_symlink

  if [[ -L "$destination" ]]; then
    echo "Refusing install: slug=$slug reason=destination_symlink state=UNSAFE_SYMLINK" >&2
    return 1
  fi

  if [[ ! -e "$destination" ]]; then
    echo "Destination preflight: slug=$slug state=ABSENT"
    return 0
  fi

  if [[ ! -d "$destination" ]]; then
    echo "Refusing install: slug=$slug reason=destination_not_directory state=UNSAFE_OTHER" >&2
    return 1
  fi

  if ! destination_real="$(realpath -e -- "$destination")"; then
    echo "Refusing install: slug=$slug reason=destination_canonicalization_failed state=UNSAFE_OTHER" >&2
    return 1
  fi

  case "$PLUGIN_ROOT_REAL" in
    /)
      if [[ "$destination_real" != /* || "$destination_real" == "/" ]]; then
        echo "Refusing install: slug=$slug reason=path_escape state=UNSAFE_PATH_ESCAPE" >&2
        return 1
      fi
      ;;
    *)
      if [[ "$destination_real" != "$PLUGIN_ROOT_REAL/"* ]]; then
        echo "Refusing install: slug=$slug reason=path_escape state=UNSAFE_PATH_ESCAPE" >&2
        return 1
      fi
      ;;
  esac
  if [[ "$(dirname -- "$destination_real")" != "$PLUGIN_ROOT_REAL" || "$(basename -- "$destination_real")" != "$slug" ]]; then
    echo "Refusing install: slug=$slug reason=path_escape state=UNSAFE_PATH_ESCAPE" >&2
    return 1
  fi

  if ! destination_mount_id="$(findmnt -n -o ID -T "$destination_real" 2>/dev/null)" || [[ -z "$destination_mount_id" ]]; then
    echo "Refusing install: slug=$slug reason=mount_inspection_failed state=UNSAFE_OTHER" >&2
    return 1
  fi
  if [[ "$destination_mount_id" != "$PLUGIN_ROOT_MOUNT_ID" ]]; then
    echo "Refusing install: slug=$slug reason=mount_boundary state=UNSAFE_PATH_ESCAPE" >&2
    return 1
  fi

  if [[ ! -r /proc/self/mountinfo ]]; then
    echo "Refusing install: slug=$slug reason=mount_inspection_failed state=UNSAFE_OTHER" >&2
    return 1
  fi
  local mount_point
  while IFS=' ' read -r _ _ _ _ mount_point _ _; do
    printf -v mount_point '%b' "$mount_point"
    if [[ "$mount_point" == "$destination_real" || "$mount_point" == "$destination_real/"* ]]; then
      echo "Refusing install: slug=$slug reason=mount_boundary state=UNSAFE_PATH_ESCAPE" >&2
      return 1
    fi
  done < /proc/self/mountinfo

  if ! nested_symlink="$(find "$destination" -type l -print -quit 2>/dev/null)"; then
    echo "Refusing install: slug=$slug reason=symlink_inspection_failed state=UNSAFE_OTHER" >&2
    return 1
  fi
  if [[ -n "$nested_symlink" ]]; then
    echo "Refusing install: slug=$slug reason=contains_symlink state=UNSAFE_CONTAINS_SYMLINK" >&2
    return 1
  fi

  echo "Destination preflight: slug=$slug state=SAFE_DIRECTORY"
}

for slug in "${ACTIVATION_ORDER[@]}"; do
  preflight_destination "$slug"
done

for slug in "${ACTIVATION_ORDER[@]}"; do
  zip_file="${ZIP_BY_SLUG[$slug]}"
  if ! wp plugin install "$zip_file" --force --path="$EVENTSALES_WP_ROOT"; then
    echo "Plugin install failed for $slug; PARTIAL_INSTALL_POSSIBLE" >&2
    exit 1
  fi
  if ! wp plugin activate "$slug" --path="$EVENTSALES_WP_ROOT"; then
    echo "Plugin activation failed for $slug; PARTIAL_INSTALL_POSSIBLE" >&2
    exit 1
  fi
  if ! status="$(wp plugin get "$slug" --field=status --path="$EVENTSALES_WP_ROOT")"; then
    echo "Plugin status check failed for $slug; PARTIAL_INSTALL_POSSIBLE" >&2
    exit 1
  fi
  if [[ "$status" != "active" ]]; then
    echo "Plugin $slug is not active after install (status=$status); PARTIAL_INSTALL_POSSIBLE" >&2
    exit 1
  fi
done

echo "Local ZIP install completed from $DIST_DIR"
echo "All four EventSales plugins are active."
echo "Run Site Health checks via WP-CLI or wp-admin Tools -> Site Health"
