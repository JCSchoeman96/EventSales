#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/integrations/wordpress/tests/published-release-validate.php"
CURL_HELPER="$ROOT/scripts/wordpress_plugin_release_http.sh"
REPOSITORY="JCSchoeman96/EventSales"
API_ROOT="https://api.github.com/repos/$REPOSITORY"
MAX_METADATA_BYTES=$((2 * 1024 * 1024))
MAX_ASSET_BYTES=$((16 * 1024 * 1024))
TAG=""
CANDIDATE_DIR=""

usage() {
  cat >&2 <<'EOF'
Usage: bash scripts/verify_wordpress_plugin_published_release.sh --tag <eventsales-wp-YYYY.MM.DD.N> [--candidate <candidate-directory>]

Reads public GitHub release metadata and assets. Does not create or change a release, tag, or repository setting.
EOF
}

fail() {
  printf 'Published release verification failed: %s\n' "$1" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      TAG="$2"
      shift 2
      ;;
    --candidate)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      CANDIDATE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$TAG" ]] || { usage; exit 2; }
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v head >/dev/null 2>&1 || fail "head is required"
command -v php >/dev/null 2>&1 || fail "PHP is required"
[[ -f "$VALIDATOR" ]] || fail "published release validator is unavailable"
[[ -f "$CURL_HELPER" ]] || fail "bounded HTTP helper is unavailable"
source "$CURL_HELPER"

if ! php -r 'require $argv[1]; exit(published_release_valid_tag($argv[2]) ? 0 : 1);' "$VALIDATOR" "$TAG"; then
  fail "tag is not a valid EventSales suite tag"
fi

if [[ -n "$CANDIDATE_DIR" ]]; then
  [[ -d "$CANDIDATE_DIR" ]] || fail "candidate directory is unavailable"
  CANDIDATE_DIR="$(cd -- "$CANDIDATE_DIR" && pwd)"
fi

TEMP_DIR="$(mktemp -d /tmp/eventsales-published-release.XXXXXX)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
ASSET_DIR="$TEMP_DIR/assets"
mkdir -p "$ASSET_DIR"

api_get_json() {
  local url="$1"
  local destination="$2"
  local headers="$TEMP_DIR/api-headers"
  local status
  local curl_result=0

  if wordpress_plugin_curl_get_limited "$MAX_METADATA_BYTES" "$headers" "$destination" \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: EventSales-WordPress-Release-Certification/1.0' \
    "$url"; then
    :
  else
    curl_result=$?
    if ((curl_result == 2)); then
      fail "GitHub API response exceeded the metadata size limit"
    fi
    fail "GitHub API request failed"
  fi

  status="$(wordpress_plugin_http_status "$headers")" || fail "GitHub API response has no HTTP status"
  [[ "$status" == "200" ]] || fail "GitHub API returned HTTP $status"
}

json_value() {
  local json_path="$1"
  local field_path="$2"
  php -r '
    $value = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
    foreach (explode(".", $argv[2]) as $key) {
        if (!is_array($value) || !array_key_exists($key, $value)) {
            exit(1);
        }
        $value = $value[$key];
    }
    if (!is_scalar($value)) {
        exit(1);
    }
    echo (string) $value;
  ' "$json_path" "$field_path"
}

asset_redirect_allowed() {
  printf '%s' "$1" | php -r '
    require $argv[1];
    $url = stream_get_contents(STDIN);
    exit(is_string($url) && published_release_redirect_url_allowed($url) ? 0 : 1);
  ' "$VALIDATOR" >/dev/null 2>&1
}

safe_url_origin() {
  printf '%s' "$1" | php -r '
    require $argv[1];
    $origin = published_release_url_origin(stream_get_contents(STDIN));
    if (!is_string($origin)) {
        exit(1);
    }
    echo $origin;
  ' "$VALIDATOR"
}

download_release_asset() {
  local asset_id="$1"
  local asset_name="$2"
  local asset_destination="$3"
  local url="$API_ROOT/releases/assets/$asset_id"
  local headers="$TEMP_DIR/asset-headers"
  local body="$TEMP_DIR/asset-body"
  local status
  local location
  local body_size
  local redirects=0
  local curl_result=0
  local request_origin
  local target_origin

  while :; do
    if wordpress_plugin_curl_get_limited "$MAX_ASSET_BYTES" "$headers" "$body" \
      -H 'Accept: application/octet-stream' \
      -H 'User-Agent: EventSales-WordPress-Release-Certification/1.0' \
      "$url"; then
      :
    else
      curl_result=$?
      if ((curl_result == 2)); then
        fail "GitHub release asset exceeded the size limit"
      fi
      fail "GitHub release asset download failed"
    fi

    status="$(wordpress_plugin_http_status "$headers")" || fail "GitHub release asset response has no HTTP status"

    case "$status" in
      200)
        [[ -s "$body" ]] || fail "GitHub returned an empty release asset"
        body_size="$(wc -c <"$body")"
        [[ "$body_size" =~ ^[0-9]+$ && "$body_size" -le "$MAX_ASSET_BYTES" ]] || fail "GitHub release asset exceeded the size limit"
        request_origin="$(safe_url_origin "$url")" || fail "GitHub release asset response origin is invalid"
        printf 'release asset %s final: HTTP 200 %s\n' "$asset_name" "$request_origin"
        mv -- "$body" "$asset_destination"
        return
        ;;
      301|302|303|307|308)
        (( redirects < 3 )) || fail "GitHub release asset exceeded the redirect limit"
        location="$(awk 'tolower($1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$headers")"
        [[ -n "$location" ]] || fail "GitHub release asset redirect has no location"
        asset_redirect_allowed "$location" || fail "GitHub release asset redirect host is not allowed"
        request_origin="$(safe_url_origin "$url")" || fail "GitHub release asset redirect source origin is invalid"
        target_origin="$(safe_url_origin "$location")" || fail "GitHub release asset redirect target origin is invalid"
        printf 'release asset %s redirect %s: HTTP %s %s -> %s\n' \
          "$asset_name" "$((redirects + 1))" "$status" "$request_origin" "$target_origin"
        url="$location"
        redirects=$((redirects + 1))
        ;;
      *)
        fail "GitHub release asset returned HTTP $status"
        ;;
    esac
  done
}

RELEASE_JSON="$TEMP_DIR/release.json"
api_get_json "$API_ROOT/releases/tags/$TAG" "$RELEASE_JSON"
php "$VALIDATOR" --metadata "$RELEASE_JSON" --tag "$TAG" --metadata-only 1

php -r '
  $release = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
  foreach ($release["assets"] as $asset) {
      echo $asset["name"], "\t", $asset["id"], PHP_EOL;
  }
' "$RELEASE_JSON" >"$TEMP_DIR/assets.tsv"

while IFS=$'\t' read -r asset_name asset_id; do
  [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || fail "GitHub release asset ID is invalid"
  download_release_asset "$asset_id" "$asset_name" "$ASSET_DIR/$asset_name"
done <"$TEMP_DIR/assets.tsv"

SOURCE_SHA="$(json_value "$ASSET_DIR/release-manifest.json" source_commit)"
SOURCE_TREE="$(json_value "$ASSET_DIR/release-manifest.json" source_tree)"
BUILD_MAIN_SHA="$(json_value "$ASSET_DIR/release-manifest.json" canonical_main_at_build)"
for identity in "$SOURCE_SHA" "$SOURCE_TREE" "$BUILD_MAIN_SHA"; do
  [[ "$identity" =~ ^[0-9a-f]{40}$ ]] || fail "Release manifest contains an invalid Git identity"
done

TAG_REF_JSON="$TEMP_DIR/tag-ref.json"
api_get_json "$API_ROOT/git/ref/tags/$TAG" "$TAG_REF_JSON"
TAG_TYPE="$(json_value "$TAG_REF_JSON" object.type)"
TAG_OBJECT_SHA="$(json_value "$TAG_REF_JSON" object.sha)"
TAG_DEPTH=0
while [[ "$TAG_TYPE" == "tag" ]]; do
  (( TAG_DEPTH < 8 )) || fail "Annotated tag chain exceeded the limit"
  TAG_OBJECT_JSON="$TEMP_DIR/tag-object.json"
  api_get_json "$API_ROOT/git/tags/$TAG_OBJECT_SHA" "$TAG_OBJECT_JSON"
  TAG_TYPE="$(json_value "$TAG_OBJECT_JSON" object.type)"
  TAG_OBJECT_SHA="$(json_value "$TAG_OBJECT_JSON" object.sha)"
  TAG_DEPTH=$((TAG_DEPTH + 1))
done
[[ "$TAG_TYPE" == "commit" && "$TAG_OBJECT_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Release tag does not resolve to a commit"

COMMIT_JSON="$TEMP_DIR/source-commit.json"
api_get_json "$API_ROOT/git/commits/$SOURCE_SHA" "$COMMIT_JSON"
COMMIT_TREE="$(json_value "$COMMIT_JSON" tree.sha)"

compare_status() {
  local base="$1"
  local head="$2"
  local destination="$TEMP_DIR/compare.json"
  api_get_json "$API_ROOT/compare/$base...$head" "$destination"
  json_value "$destination" status
}

SOURCE_TO_MAIN="$(compare_status "$SOURCE_SHA" main)"
SOURCE_TO_BUILD="$(compare_status "$SOURCE_SHA" "$BUILD_MAIN_SHA")"
BUILD_TO_MAIN="$(compare_status "$BUILD_MAIN_SHA" main)"
ANCESTRY_JSON="$(php -r 'echo json_encode(["source_to_main"=>$argv[1],"source_to_build"=>$argv[2],"build_to_main"=>$argv[3]], JSON_UNESCAPED_SLASHES);' "$SOURCE_TO_MAIN" "$SOURCE_TO_BUILD" "$BUILD_TO_MAIN")"

if [[ -n "$CANDIDATE_DIR" ]]; then
  php "$VALIDATOR" --metadata "$RELEASE_JSON" --tag "$TAG" \
    --tag-target "$TAG_OBJECT_SHA" --source-tree "$COMMIT_TREE" \
    --ancestry "$ANCESTRY_JSON" --assets-dir "$ASSET_DIR" --candidate-dir "$CANDIDATE_DIR"
else
  php "$VALIDATOR" --metadata "$RELEASE_JSON" --tag "$TAG" \
    --tag-target "$TAG_OBJECT_SHA" --source-tree "$COMMIT_TREE" \
    --ancestry "$ANCESTRY_JSON" --assets-dir "$ASSET_DIR"
fi
