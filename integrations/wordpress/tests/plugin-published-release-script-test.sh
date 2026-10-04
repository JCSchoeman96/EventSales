#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/verify_wordpress_plugin_published_release.sh"

fail() {
  printf 'plugin-published-release-script-test: %s\n' "$1" >&2
  exit 1
}

[[ -f "$SCRIPT" ]] || fail "published-release verifier is unavailable"

curl_call_count="$(grep -F -c 'command curl -q' "$SCRIPT" || true)"
[[ "$curl_call_count" == "2" ]] || fail "each verifier curl call must disable curlrc before other options"
grep -Fq -- '--max-filesize "$MAX_METADATA_BYTES"' "$SCRIPT" || fail "GitHub API downloads must have a byte limit"
grep -Fq -- '--max-filesize "$MAX_ASSET_BYTES"' "$SCRIPT" || fail "release asset downloads must have a byte limit"

command -v curl >/dev/null 2>&1 || fail "curl is required for the curlrc isolation check"
CONFIG_DIR="$(mktemp -d /tmp/eventsales-curlrc-test.XXXXXX)"
trap 'rm -rf -- "$CONFIG_DIR"' EXIT
printf '%s\n' '--help' >"$CONFIG_DIR/.curlrc"

configured_output="$(env CURL_HOME="$CONFIG_DIR" XDG_CONFIG_HOME="$CONFIG_DIR" \
  curl --noproxy '*' --connect-timeout 1 --max-time 1 http://127.0.0.1:1/ 2>&1 || true)"
hermetic_output="$(env CURL_HOME="$CONFIG_DIR" XDG_CONFIG_HOME="$CONFIG_DIR" \
  curl -q --noproxy '*' --connect-timeout 1 --max-time 1 http://127.0.0.1:1/ 2>&1 || true)"
[[ "$configured_output" == *'Usage: curl'* ]] || fail "synthetic curlrc did not affect the control invocation"
[[ "$hermetic_output" != *'Usage: curl'* ]] || fail "curl -q did not ignore the synthetic curlrc"

printf 'plugin-published-release-script-test: passed\n'
