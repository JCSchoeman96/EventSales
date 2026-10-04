#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=""
FROM_MANIFEST=""
TO_MANIFEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:?--mode requires upgrade or rollback}"
      shift 2
      ;;
    --from)
      FROM_MANIFEST="${2:?--from requires a path}"
      shift 2
      ;;
    --to)
      TO_MANIFEST="${2:?--to requires a path}"
      shift 2
      ;;
    -h | --help)
      echo "Usage: bash scripts/check_wordpress_plugin_release_transition.sh --mode upgrade|rollback --from <release-manifest.json> --to <release-manifest.json>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "upgrade" && "$MODE" != "rollback" ]]; then
  echo "--mode must be upgrade or rollback" >&2
  exit 1
fi

if [[ -z "$FROM_MANIFEST" || -z "$TO_MANIFEST" ]]; then
  echo "--from and --to are required" >&2
  exit 1
fi

php "$ROOT/integrations/wordpress/tests/release-transition-validate.php" \
  --mode "$MODE" \
  --from "$FROM_MANIFEST" \
  --to "$TO_MANIFEST"
