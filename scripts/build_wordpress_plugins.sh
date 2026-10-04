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
    -h | --help)
      echo "Usage: bash scripts/build_wordpress_plugins.sh [--ref <git-ref>]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SUITE_GIT_PATH="integrations/wordpress/eventsales-plugin-suite.json"
SOURCE_COMMIT="$(git rev-parse "${REF}^{commit}")"
SOURCE_TREE="$(git rev-parse "${SOURCE_COMMIT}^{tree}")"
HEAD_COMMIT="$(git rev-parse HEAD)"

SUITE_JSON="$(mktemp)"
cleanup_suite() {
  rm -f "$SUITE_JSON"
}
trap cleanup_suite EXIT

if ! git show "$SOURCE_COMMIT:$SUITE_GIT_PATH" >"$SUITE_JSON" 2>/dev/null; then
  echo "Missing suite manifest at $SOURCE_COMMIT:$SUITE_GIT_PATH" >&2
  exit 1
fi

mapfile -t PLUGIN_SLUGS < <(php -r '
$data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
foreach ($data["plugins"] as $plugin) {
    echo $plugin["slug"], PHP_EOL;
}
' "$SUITE_JSON")

PLUGIN_PREFIX="integrations/wordpress"
PLUGIN_PATHS=("$SUITE_GIT_PATH")
for slug in "${PLUGIN_SLUGS[@]}"; do
  PLUGIN_PATHS+=("$PLUGIN_PREFIX/$slug")
done

if [[ "$SOURCE_COMMIT" == "$HEAD_COMMIT" ]]; then
  for path in "${PLUGIN_PATHS[@]}"; do
    if ! git diff --quiet "$SOURCE_COMMIT" -- "$path"; then
      echo "Refusing build: unstaged changes under $path vs $SOURCE_COMMIT" >&2
      exit 1
    fi
    if ! git diff --cached --quiet "$SOURCE_COMMIT" -- "$path"; then
      echo "Refusing build: staged changes under $path vs $SOURCE_COMMIT" >&2
      exit 1
    fi
  done

  for path in "${PLUGIN_PATHS[@]}"; do
    while IFS= read -r untracked; do
      [[ -z "$untracked" ]] && continue
      echo "Refusing build: untracked file would be excluded from provenance: $untracked" >&2
      exit 1
    done < <(git ls-files --others --exclude-standard -- "$path")
  done
fi

OUT_DIR="$ROOT/tmp/wordpress-plugin-dist/$SOURCE_COMMIT"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

STAGING="$(mktemp -d)"
cleanup_staging() {
  rm -rf "$STAGING"
}
trap 'cleanup_suite; cleanup_staging' EXIT

DISTRIBUTION_FORMAT_VERSION="1"
MANIFEST_PLUGINS=()

for slug in "${PLUGIN_SLUGS[@]}"; do
  plugin_meta="$(php -r '
$data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
foreach ($data["plugins"] as $plugin) {
    if ($plugin["slug"] === $argv[2]) {
        echo json_encode($plugin, JSON_THROW_ON_ERROR);
        exit(0);
    }
}
fwrite(STDERR, "Unknown slug\n");
exit(1);
' "$SUITE_JSON" "$slug")"

  marketing_version="$(php -r 'echo json_decode($argv[1], true)["marketing_version"];' "$plugin_meta")"
  archive_name="${slug}-${marketing_version}.zip"
  plugin_stage="$STAGING/$slug"
  rm -rf "$plugin_stage"
  mkdir -p "$plugin_stage"

  packaged_files=()
  while read -r mode objtype _object git_path; do
    [[ -z "$git_path" ]] && continue
    if [[ "$objtype" != "blob" ]]; then
      echo "Rejected git object type ${objtype} at ${git_path}" >&2
      exit 1
    fi
    if [[ "$mode" == "120000" ]]; then
      echo "Rejected symlink at ${git_path}" >&2
      exit 1
    fi
    if [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
      echo "Rejected unexpected git mode ${mode} at ${git_path}" >&2
      exit 1
    fi
    rel="${git_path#"$PLUGIN_PREFIX/$slug/"}"
    case "$rel" in
      tests/* | */tests/*)
        continue
        ;;
    esac
    case "$rel" in
      ../* | */../*)
        echo "Path traversal in source path: $rel" >&2
        exit 1
        ;;
    esac
    if [[ "$rel" =~ ^[A-Za-z]: ]]; then
      echo "Windows drive path in source path: $rel" >&2
      exit 1
    fi
    case "$rel" in
      *.env | *.env.* | wp-config.php)
        echo "Excluded env/config source path: $rel" >&2
        exit 1
        ;;
    esac
    if [[ "$rel" != *.php && "$rel" != README.md ]]; then
      echo "Unexpected source file for packaging: $rel" >&2
      exit 1
    fi
    dest="$plugin_stage/$rel"
    mkdir -p "$(dirname "$dest")"
    git show "$SOURCE_COMMIT:$git_path" >"$dest"
    packaged_files+=("$rel")
  done < <(git ls-tree -r "$SOURCE_TREE" "$PLUGIN_PREFIX/$slug")

  main_file="$(php -r 'echo json_decode($argv[1], true)["main_file"];' "$plugin_meta")"
  if [[ ! -f "$plugin_stage/$main_file" ]]; then
    echo "Missing main file in package: $slug/$main_file" >&2
    exit 1
  fi

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ "$rel" == *.php ]]; then
      if ! php -l "$plugin_stage/$rel" >/dev/null; then
        php -l "$plugin_stage/$rel" >&2 || true
        exit 1
      fi
    fi
  done < <(printf '%s\n' "${packaged_files[@]}")

  zip_path="$OUT_DIR/$archive_name"
  (
    cd "$STAGING"
    zip -qr "$zip_path" "$slug"
  )

  archive_sha256="$(sha256sum "$zip_path" | awk '{print $1}')"
  MANIFEST_PLUGINS+=("$slug|$archive_name|$archive_sha256|$plugin_meta")
done

SHA256SUMS="$OUT_DIR/SHA256SUMS"
: > "$SHA256SUMS"
for entry in "${MANIFEST_PLUGINS[@]}"; do
  IFS='|' read -r _ archive_name archive_sha256 _ <<<"$entry"
  printf '%s  %s\n' "$archive_sha256" "$archive_name" >>"$SHA256SUMS"
done

php -r '
$out = $argv[1];
$format = $argv[2];
$commit = $argv[3];
$tree = $argv[4];
$suitePath = $argv[5];
$entries = array_slice($argv, 6);
$plugins = [];
foreach ($entries as $entry) {
    [$slug, $archive, $sha, $metaJson] = explode("|", $entry, 4);
    $meta = json_decode($metaJson, true, 512, JSON_THROW_ON_ERROR);
    $plugins[] = array_merge(
        [
            "slug" => $slug,
            "archive_filename" => $archive,
            "archive_sha256" => $sha,
        ],
        $meta
    );
}
$manifest = [
    "distribution_format_version" => $format,
    "source_commit" => $commit,
    "source_tree" => $tree,
    "suite_manifest_git_path" => $suitePath,
    "deterministic_source_content" => true,
    "deterministic_archive_bytes" => false,
    "plugins" => $plugins,
];
file_put_contents($out, json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
' "$OUT_DIR/manifest.json" "$DISTRIBUTION_FORMAT_VERSION" "$SOURCE_COMMIT" "$SOURCE_TREE" "$SUITE_GIT_PATH" "${MANIFEST_PLUGINS[@]}"

echo "Built WordPress plugin distribution:"
echo "  commit: $SOURCE_COMMIT"
echo "  tree:   $SOURCE_TREE"
echo "  output: $OUT_DIR"
ls -1 "$OUT_DIR"
