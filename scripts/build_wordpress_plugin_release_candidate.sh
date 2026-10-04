#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib/wordpress_plugin_release_common.sh
source "$ROOT/scripts/lib/wordpress_plugin_release_common.sh"

SOURCE_SHA=""
RELEASE_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      SOURCE_SHA="${2:?--ref requires a value}"
      shift 2
      ;;
    --release-id)
      RELEASE_ID="${2:?--release-id requires a value}"
      shift 2
      ;;
    -h | --help)
      echo "Usage: bash scripts/build_wordpress_plugin_release_candidate.sh --ref <40-char-sha> --release-id <YYYY.MM.DD.N>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_SHA" || -z "$RELEASE_ID" ]]; then
  echo "Both --ref and --release-id are required" >&2
  exit 1
fi

SOURCE_SHA="$(printf '%s' "$SOURCE_SHA" | tr 'A-Z' 'a-z')"
validate_source_commit_sha "$SOURCE_SHA"
validate_suite_release_id "$RELEASE_ID"
assert_source_on_canonical_main "$SOURCE_SHA"

CANONICAL_MAIN_AT_BUILD="$(resolve_canonical_main_sha)"
SUGGESTED_TAG="$(suggested_tag_for_release_id "$RELEASE_ID")"

bash "$ROOT/scripts/build_wordpress_plugins.sh" --ref "$SOURCE_SHA"

DIST_DIR="$ROOT/tmp/wordpress-plugin-dist/$SOURCE_SHA"
if [[ ! -f "$DIST_DIR/manifest.json" ]]; then
  echo "Distribution build did not produce manifest.json" >&2
  exit 1
fi

OUT_DIR="$ROOT/tmp/wordpress-plugin-release/$SOURCE_SHA/$RELEASE_ID"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cp -a "$DIST_DIR"/*.zip "$OUT_DIR/"
cp "$DIST_DIR/manifest.json" "$OUT_DIR/manifest.json"
cp "$DIST_DIR/SHA256SUMS" "$OUT_DIR/SHA256SUMS"

SUITE_GIT_PATH="integrations/wordpress/eventsales-plugin-suite.json"
SOURCE_TREE="$(git rev-parse "${SOURCE_SHA}^{tree}")"
SUITE_JSON="$(mktemp)"
trap 'rm -f "$SUITE_JSON"' EXIT
git show "$SOURCE_SHA:$SUITE_GIT_PATH" >"$SUITE_JSON"

php -r '
$root = $argv[1];
$outDir = $argv[2];
$releaseId = $argv[3];
$suggestedTag = $argv[4];
$sourceCommit = $argv[5];
$sourceTree = $argv[6];
$canonicalMain = $argv[7];
$suitePath = $argv[8];
$suiteJsonPath = $argv[9];
$distManifestPath = $outDir . "/manifest.json";

$suite = json_decode(file_get_contents($suiteJsonPath), true, 512, JSON_THROW_ON_ERROR);
$distManifest = json_decode(file_get_contents($distManifestPath), true, 512, JSON_THROW_ON_ERROR);

$plugins = [];
foreach ($distManifest["plugins"] as $entry) {
    $row = [
        "slug" => $entry["slug"],
        "main_file" => $entry["main_file"],
        "marketing_version" => $entry["marketing_version"],
        "archive_filename" => $entry["archive_filename"],
        "archive_sha256" => $entry["archive_sha256"],
    ];
    $skip = array_flip(["slug", "main_file", "marketing_version", "archive_filename", "archive_sha256"]);
    foreach ($entry as $key => $value) {
        if (!isset($skip[$key])) {
            $row[$key] = $value;
        }
    }
    $plugins[] = $row;
}

$releaseManifest = [
    "release_manifest_format_version" => "1",
    "suite_release_id" => $releaseId,
    "suggested_tag" => $suggestedTag,
    "source_commit" => $sourceCommit,
    "source_tree" => $sourceTree,
    "canonical_main_at_build" => $canonicalMain,
    "suite_manifest_git_path" => $suitePath,
    "distribution_format_version" => (string) ($distManifest["distribution_format_version"] ?? "1"),
    "requires_wordpress" => (string) ($suite["requires_at_least_wordpress"] ?? ""),
    "requires_php" => (string) ($suite["requires_php"] ?? ""),
    "plugins" => $plugins,
    "deterministic_source_content" => (bool) ($distManifest["deterministic_source_content"] ?? false),
    "deterministic_archive_bytes" => (bool) ($distManifest["deterministic_archive_bytes"] ?? false),
];

$releasePath = $outDir . "/release-manifest.json";
file_put_contents(
    $releasePath,
    json_encode($releaseManifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL
);

$checksumTargets = [];
foreach (glob($outDir . "/*.zip") ?: [] as $zip) {
    $checksumTargets[] = basename($zip);
}
$checksumTargets[] = "manifest.json";
$checksumTargets[] = "release-manifest.json";
sort($checksumTargets);

$sumsPath = $outDir . "/RELEASE_SHA256SUMS";
$lines = [];
foreach ($checksumTargets as $name) {
    $path = $outDir . "/" . $name;
    $hash = hash_file("sha256", $path);
    $lines[] = $hash . "  " . $name;
}
file_put_contents($sumsPath, implode(PHP_EOL, $lines) . PHP_EOL);
' "$ROOT" "$OUT_DIR" "$RELEASE_ID" "$SUGGESTED_TAG" "$SOURCE_SHA" "$SOURCE_TREE" "$CANONICAL_MAIN_AT_BUILD" "$SUITE_GIT_PATH" "$SUITE_JSON"

bash "$ROOT/scripts/verify_wordpress_plugin_release_candidate.sh" "$OUT_DIR"

echo "Release candidate built:"
echo "  source_commit:       $SOURCE_SHA"
echo "  suite_release_id:    $RELEASE_ID"
echo "  suggested_tag:       $SUGGESTED_TAG"
echo "  canonical_main:      $CANONICAL_MAIN_AT_BUILD"
echo "  output:              $OUT_DIR"
