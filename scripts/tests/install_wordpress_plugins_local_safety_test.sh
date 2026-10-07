#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/install_wordpress_plugins_local.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/eventsales-wp-installer-safety.XXXXXX")"
ORIGINAL_PATH="$PATH"
trap 'rm -rf "$TMP_ROOT"' EXIT

SLUGS=(
  eventsales-tickera-catalog-feed
  eventsales-woo-order-index-feed
  eventsales-woo-order-line-identity
  eventsales-integration-health
)

fail() {
  echo "install_wordpress_plugins_local_safety_test: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label (expected '$expected', got '$actual')"
}

setup_case() {
  local name="$1"
  CASE="$TMP_ROOT/$name"
  mkdir -p "$CASE/repo/scripts" "$CASE/repo/integrations/wordpress/tests" "$CASE/dist" "$CASE/wp" "$CASE/fakebin"
  cp "$INSTALLER" "$CASE/repo/scripts/install_wordpress_plugins_local.sh"

  cat > "$CASE/repo/scripts/verify_wordpress_plugin_packages.sh" <<'FAKE_VERIFIER'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify\n' >> "$FAKE_EVENTS"
if [[ "${FAKE_VERIFY_FAIL:-0}" == "1" ]]; then
  echo "synthetic package verification failure" >&2
  exit 1
fi
FAKE_VERIFIER
  chmod +x "$CASE/repo/scripts/verify_wordpress_plugin_packages.sh"

  cat > "$CASE/fakebin/wp" <<'FAKE_WP'
#!/usr/bin/env bash
set -euo pipefail
printf 'wp %s\n' "$*" >> "$FAKE_EVENTS"

case "${1:-}" in
  option)
    [[ "${2:-}" == "get" ]] || exit 2
    case "${3:-}" in
      home) option_value="$FAKE_HOME_URL" ;;
      siteurl) option_value="$FAKE_SITEURL_URL" ;;
      *) exit 2 ;;
    esac
    printf '%s\n' "$option_value"
    if [[ "${FAKE_FAIL_OPTION:-}" == "${3:-}" ]]; then
      exit 23
    fi
    ;;
  eval)
    [[ "${2:-}" == "echo WP_PLUGIN_DIR;" ]] || exit 2
    printf '%s\n' "$FAKE_PLUGIN_DIR"
    ;;
  plugin)
    case "${2:-}" in
      install)
        printf '%s %s\n' "${2}" "${3:-}" >> "$FAKE_MUTATIONS"
        if [[ -n "${FAKE_FAIL_INSTALL_ARCHIVE:-}" && "${3:-}" == "$FAKE_FAIL_INSTALL_ARCHIVE" ]]; then
          exit 23
        fi
        ;;
      activate)
        printf '%s %s\n' "${2}" "${3:-}" >> "$FAKE_MUTATIONS"
        ;;
      get)
        printf 'active\n'
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
FAKE_WP
  chmod +x "$CASE/fakebin/wp"

  for slug in "${SLUGS[@]}"; do
    printf 'synthetic zip for %s\n' "$slug" > "$CASE/dist/$slug-0.1.0.zip"
  done

  : > "$CASE/wp.log"
  : > "$CASE/events.log"
  : > "$CASE/mutations.log"
  export FAKE_WP_LOG="$CASE/wp.log"
  export FAKE_EVENTS="$CASE/events.log"
  export FAKE_MUTATIONS="$CASE/mutations.log"
  export FAKE_HOME_URL="http://localhost:10059"
  export FAKE_SITEURL_URL="http://localhost:10059"
  export FAKE_PLUGIN_DIR="$CASE/wp/wp-content/plugins"
  export FAKE_VERIFY_FAIL=0
  export FAKE_FAIL_OPTION=""
  export FAKE_FAIL_INSTALL_ARCHIVE=""
  export FAKE_REALPATH_ESCAPE_INPUT=""
  export FAKE_REALPATH_ESCAPE_TARGET=""
  export EVENTSALES_WP_ROOT="$CASE/wp"
  export EVENTSALES_ALLOW_LOCAL_WP_PLUGIN_REPLACE=1
  export PATH="$CASE/fakebin:$ORIGINAL_PATH"
  mkdir -p "$FAKE_PLUGIN_DIR"
}

run_installer() {
  bash "$CASE/repo/scripts/install_wordpress_plugins_local.sh" "$CASE/dist"
}

install_count() {
  awk '$1 == "install" { count++ } END { print count + 0 }' "$FAKE_MUTATIONS"
}

assert_preflight_states() {
  local output_file="$1"
  local expected_state="$2"
  local slug
  for slug in "${SLUGS[@]}"; do
    grep -F "slug=$slug state=$expected_state" "$output_file" >/dev/null || fail "missing $expected_state preflight for $slug"
  done
}

test_safe_absent_destinations() {
  setup_case safe-absent
  local output="$CASE/output.log"
  run_installer > "$output" 2>&1 || fail "safe absent destinations were rejected"
  assert_eq "$(install_count)" "4" "safe absent destinations install count"
  assert_preflight_states "$output" ABSENT
}

test_safe_real_directories() {
  setup_case safe-directories
  local slug
  for slug in "${SLUGS[@]}"; do
    mkdir -p "$FAKE_PLUGIN_DIR/$slug"
  done
  local output="$CASE/output.log"
  run_installer > "$output" 2>&1 || fail "safe real directories were rejected"
  assert_eq "$(install_count)" "4" "safe real destinations install count"
  assert_preflight_states "$output" SAFE_DIRECTORY
}

make_synthetic_worktree() {
  local target="$1"
  mkdir -p "$target"
  printf 'tracked file A\n' > "$target/tracked-a.php"
  printf 'tracked file B\n' > "$target/tracked-b.php"
  git init -q "$target"
  git -C "$target" add tracked-a.php tracked-b.php
  GIT_AUTHOR_NAME='EventSales Safety Test' \
  GIT_AUTHOR_EMAIL='eventsales-safety@example.invalid' \
  GIT_COMMITTER_NAME='EventSales Safety Test' \
  GIT_COMMITTER_EMAIL='eventsales-safety@example.invalid' \
    git -C "$target" commit -q -m 'synthetic plugin worktree'
}

test_direct_order_line_symlink_preserves_worktree() {
  setup_case order-line-symlink
  local target="$CASE/worktree/integrations/wordpress/eventsales-woo-order-line-identity"
  make_synthetic_worktree "$target"
  local before after output="$CASE/output.log"
  before="$(sha256sum "$target/tracked-a.php" "$target/tracked-b.php")"
  ln -s "$target" "$FAKE_PLUGIN_DIR/${SLUGS[2]}"

  if run_installer > "$output" 2>&1; then
    fail "order-line destination symlink was accepted"
  fi
  grep -F "slug=${SLUGS[2]} reason=destination_symlink" "$output" >/dev/null || fail "order-line symlink reason was not reported"
  assert_eq "$(install_count)" "0" "order-line symlink install count"
  after="$(sha256sum "$target/tracked-a.php" "$target/tracked-b.php")"
  assert_eq "$after" "$before" "synthetic worktree tracked file hashes"
  [[ -f "$target/tracked-a.php" && -f "$target/tracked-b.php" ]] || fail "synthetic worktree files were removed"
}

test_fourth_plugin_symlink_preflights_every_destination() {
  setup_case health-symlink
  mkdir -p "$CASE/health-target"
  ln -s "$CASE/health-target" "$FAKE_PLUGIN_DIR/${SLUGS[3]}"
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "Integration Health destination symlink was accepted"
  fi
  grep -F "slug=${SLUGS[3]} reason=destination_symlink" "$output" >/dev/null || fail "Integration Health symlink reason was not reported"
  grep -F "slug=${SLUGS[0]} state=ABSENT" "$output" >/dev/null || fail "first destination was not preflighted"
  grep -F "slug=${SLUGS[1]} state=ABSENT" "$output" >/dev/null || fail "second destination was not preflighted"
  grep -F "slug=${SLUGS[2]} state=ABSENT" "$output" >/dev/null || fail "third destination was not preflighted"
  assert_eq "$(install_count)" "0" "fourth-plugin symlink install count"
}

test_nested_symlink_fails_closed() {
  setup_case nested-symlink
  local outside="$CASE/outside"
  mkdir -p "$FAKE_PLUGIN_DIR/${SLUGS[0]}" "$outside"
  printf 'outside sentinel\n' > "$outside/sentinel.txt"
  local before after output="$CASE/output.log"
  before="$(sha256sum "$outside/sentinel.txt")"
  ln -s "$outside" "$FAKE_PLUGIN_DIR/${SLUGS[0]}/vendor-link"
  if run_installer > "$output" 2>&1; then
    fail "nested destination symlink was accepted"
  fi
  grep -F "slug=${SLUGS[0]} reason=contains_symlink" "$output" >/dev/null || fail "nested symlink reason was not reported"
  assert_eq "$(install_count)" "0" "nested symlink install count"
  after="$(sha256sum "$outside/sentinel.txt")"
  assert_eq "$after" "$before" "nested symlink outside target hash"
}

test_canonical_path_escape_fails_closed() {
  setup_case path-escape
  local destination="$FAKE_PLUGIN_DIR/${SLUGS[0]}"
  mkdir -p "$destination" "$CASE/outside"
  cat > "$CASE/fakebin/realpath" <<'FAKE_REALPATH'
#!/usr/bin/env bash
set -euo pipefail
last="${!#}"
if [[ "$last" == "$FAKE_REALPATH_ESCAPE_INPUT" ]]; then
  printf '%s\n' "$FAKE_REALPATH_ESCAPE_TARGET"
else
  exec /usr/bin/realpath "$@"
fi
FAKE_REALPATH
  chmod +x "$CASE/fakebin/realpath"
  export FAKE_REALPATH_ESCAPE_INPUT="$destination"
  export FAKE_REALPATH_ESCAPE_TARGET="$CASE/outside"
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "canonical path escape was accepted"
  fi
  grep -F "slug=${SLUGS[0]} reason=path_escape" "$output" >/dev/null || fail "path escape reason was not reported"
  assert_eq "$(install_count)" "0" "path escape install count"
}

test_plugin_root_symlink_fails_closed() {
  setup_case plugin-root-symlink
  local real_root="$CASE/real-plugins"
  mkdir -p "$real_root"
  rmdir "$FAKE_PLUGIN_DIR"
  ln -s "$real_root" "$FAKE_PLUGIN_DIR"
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "WP_PLUGIN_DIR symlink was accepted"
  fi
  grep -F 'plugin root is a symlink' "$output" >/dev/null || fail "plugin-root symlink failure was not reported"
  assert_eq "$(install_count)" "0" "plugin-root symlink install count"
}

test_wrong_home_and_siteurl_fail_before_mutation() {
  setup_case wrong-local-url
  export FAKE_HOME_URL="https://example.invalid"
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "wrong home URL was accepted"
  fi
  assert_eq "$(install_count)" "0" "wrong-home install count"

  setup_case wrong-siteurl
  export FAKE_SITEURL_URL="https://example.invalid"
  output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "wrong siteurl was accepted"
  fi
  assert_eq "$(install_count)" "0" "wrong-siteurl install count"
}

test_failed_url_reads_fail_even_when_stdout_looks_local() {
  setup_case failed-home-read
  export FAKE_FAIL_OPTION="home"
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "failed home option read was accepted based on stdout"
  fi
  grep -F 'could not read WordPress home URL' "$output" >/dev/null || fail "failed home option read was not reported"
  assert_eq "$(install_count)" "0" "failed-home-read install count"

  setup_case failed-siteurl-read
  export FAKE_FAIL_OPTION="siteurl"
  output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "failed siteurl option read was accepted based on stdout"
  fi
  grep -F 'could not read WordPress siteurl' "$output" >/dev/null || fail "failed siteurl option read was not reported"
  assert_eq "$(install_count)" "0" "failed-siteurl-read install count"
}

test_package_verification_failure_precedes_plugin_root_resolution() {
  setup_case invalid-distribution
  export FAKE_VERIFY_FAIL=1
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "invalid distribution was accepted"
  fi
  assert_eq "$(install_count)" "0" "invalid-distribution install count"
  if grep -F 'eval echo WP_PLUGIN_DIR;' "$FAKE_EVENTS" >/dev/null; then
    fail "WP_PLUGIN_DIR was resolved before package verification passed"
  fi
}

test_preflight_order_is_before_first_install() {
  setup_case preflight-order
  local output="$CASE/output.log"
  bash -x "$CASE/repo/scripts/install_wordpress_plugins_local.sh" "$CASE/dist" > "$output" 2>&1 || fail "safe fixture was rejected"
  local last_preflight first_install
  last_preflight="$(grep -n -F "+ preflight_destination ${SLUGS[3]}" "$output" | tail -n 1 | cut -d: -f1)"
  first_install="$(grep -n '+ wp plugin install ' "$output" | head -n 1 | cut -d: -f1)"
  [[ -n "$last_preflight" && -n "$first_install" ]] || fail "preflight/install evidence missing"
  (( last_preflight < first_install )) || fail "first plugin install began before fourth destination preflight"
  assert_eq "$(grep -c '^Destination preflight: slug=.* state=' "$output")" "4" "destination preflight count"
}

test_failed_replacement_reports_partial_install_risk() {
  setup_case partial-install
  export FAKE_FAIL_INSTALL_ARCHIVE="$CASE/dist/${SLUGS[1]}-0.1.0.zip"
  local output="$CASE/output.log"
  if run_installer > "$output" 2>&1; then
    fail "synthetic plugin replacement failure was ignored"
  fi
  grep -F 'PARTIAL_INSTALL_POSSIBLE' "$output" >/dev/null || fail "partial-install risk was not reported"
  assert_eq "$(install_count)" "2" "replacement failure install attempts"
  if grep -F "${SLUGS[2]}" "$FAKE_MUTATIONS" >/dev/null; then
    fail "installer continued after replacement failure"
  fi
}

test_safe_absent_destinations
test_safe_real_directories
test_direct_order_line_symlink_preserves_worktree
test_fourth_plugin_symlink_preflights_every_destination
test_nested_symlink_fails_closed
test_canonical_path_escape_fails_closed
test_plugin_root_symlink_fails_closed
test_wrong_home_and_siteurl_fail_before_mutation
test_failed_url_reads_fail_even_when_stdout_looks_local
test_package_verification_failure_precedes_plugin_root_resolution
test_preflight_order_is_before_first_install
test_failed_replacement_reports_partial_install_risk

echo "install_wordpress_plugins_local_safety_test: passed"
