#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/verify_wordpress_plugin_published_release.sh"
CURL_HELPER="$ROOT/scripts/wordpress_plugin_release_http.sh"

fail() {
  printf 'plugin-published-release-script-test: %s\n' "$1" >&2
  exit 1
}

[[ -f "$SCRIPT" ]] || fail "published-release verifier is unavailable"
[[ -f "$CURL_HELPER" ]] || fail "bounded curl helper is unavailable"
source "$CURL_HELPER"

curl_call_count="$(grep -F -c 'command curl -q' "$CURL_HELPER" || true)"
[[ "$curl_call_count" == "1" ]] || fail "bounded response helper must disable curlrc before other options"
grep -Fq 'wordpress_plugin_curl_get_limited "$MAX_METADATA_BYTES"' "$SCRIPT" || fail "GitHub API responses must use bounded streaming downloads"
grep -Fq 'wordpress_plugin_curl_get_limited "$MAX_ASSET_BYTES"' "$SCRIPT" || fail "release assets must use bounded streaming downloads"

CONFIG_DIR="$(mktemp -d /tmp/eventsales-curl-limit-test.XXXXXX)"
trap 'rm -rf -- "$CONFIG_DIR"' EXIT
SMALL_FILE="$CONFIG_DIR/exact-limit"
LARGE_FILE="$CONFIG_DIR/over-limit"
SMALL_BODY="$CONFIG_DIR/small-body"
LARGE_BODY="$CONFIG_DIR/large-body"
SMALL_HEADERS="$CONFIG_DIR/small-headers"
LARGE_HEADERS="$CONFIG_DIR/large-headers"
LIMIT=4096
head -c "$LIMIT" /dev/zero >"$SMALL_FILE"
head -c "$((LIMIT * 4))" /dev/zero >"$LARGE_FILE"

wordpress_plugin_curl_get_limited "$LIMIT" "$SMALL_HEADERS" "$SMALL_BODY" "file://$SMALL_FILE" \
  || fail "response exactly at the byte limit must succeed"
[[ "$(wc -c <"$SMALL_BODY")" == "$LIMIT" ]] || fail "exact-limit response was truncated"

if wordpress_plugin_curl_get_limited "$LIMIT" "$LARGE_HEADERS" "$LARGE_BODY" "file://$LARGE_FILE"; then
  fail "oversized response must fail"
else
  oversized_status=$?
fi
[[ "$oversized_status" == "2" ]] || fail "oversized response must return the size-limit status"
[[ "$(wc -c <"$LARGE_BODY")" == "$((LIMIT + 1))" ]] || fail "oversized response body must be capped at limit plus one byte"

STATUS_HEADERS="$CONFIG_DIR/status-headers"
printf 'HTTP/2 302\r\nLocation: https://release-assets.githubusercontent.com/redacted\r\n\r\nHTTP/2 200\r\n\r\n' >"$STATUS_HEADERS"
[[ "$(wordpress_plugin_http_status "$STATUS_HEADERS")" == "200" ]] || fail "last HTTP response status must be selected"

command -v curl >/dev/null 2>&1 || fail "curl is required for the curlrc isolation check"
CONFIG_OUTPUT="$CONFIG_DIR/curlrc-output"
INPUT_FILE="$CONFIG_DIR/payload"
printf 'curlrc fixture payload' >"$INPUT_FILE"
printf 'output = "%s"\n' "$CONFIG_OUTPUT" >"$CONFIG_DIR/.curlrc"
printf 'output = "%s"\n' "$CONFIG_OUTPUT" >"$CONFIG_DIR/curlrc"
INPUT_URL="file://$INPUT_FILE"

configured_output="$(env CURL_HOME="$CONFIG_DIR" XDG_CONFIG_HOME="$CONFIG_DIR" curl "$INPUT_URL" 2>/dev/null)"
[[ -f "$CONFIG_OUTPUT" && "$(cat "$CONFIG_OUTPUT")" == 'curlrc fixture payload' ]] || fail "synthetic curlrc did not affect the control invocation"
hermetic_output="$(env CURL_HOME="$CONFIG_DIR" XDG_CONFIG_HOME="$CONFIG_DIR" curl -q "$INPUT_URL" 2>/dev/null)"
[[ "$hermetic_output" == 'curlrc fixture payload' ]] || fail "curl -q did not ignore the synthetic curlrc"

printf 'plugin-published-release-script-test: passed\n'
