#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
generate_source="$repo_root/deploy/vps/operator/agent-eventsales-v2-generate-secrets"
render_source="$repo_root/deploy/vps/operator/agent-eventsales-v2-render-config"
sudoers_source="$repo_root/deploy/vps/operator/agent-eventsales-v2.sudoers"
expected_base='/root/eventsales-prod'
expected_stage='/root/eventsales-prod/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts'
secret_sentinel='WRAPPER_SECRET_SENTINEL_MUST_NOT_APPEAR'

for source in "$generate_source" "$render_source" "$sudoers_source"; do
  [[ -f "$source" && ! -L "$source" ]] || {
    printf 'FAIL: required source missing or symlinked: %s\n' "$source" >&2
    exit 1
  }
done

grep -Fq "$expected_base/secrets-v1" "$generate_source"
grep -Fq "$expected_stage/generate-secrets.sh" "$generate_source"
grep -Fq "$expected_base/secrets-v1" "$render_source"
grep -Fq "$expected_stage/render-runtime-config.sh" "$render_source"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/eventsales-v2-wrappers.XXXXXX")
chmod 0755 "$temporary_root"
fixture=''
passes=0

cleanup_fixture() {
  if [[ -n "$fixture" && -d "$fixture" ]]; then
    chmod -R u+w "$fixture" 2>/dev/null || true
    rm -rf -- "$fixture"
  fi
  fixture=''
}

cleanup() {
  cleanup_fixture
  chmod -R u+w "$temporary_root" 2>/dev/null || true
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

pass() {
  passes=$((passes + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

new_fixture() {
  cleanup_fixture
  fixture=$(mktemp -d "$temporary_root/fixture.XXXXXX")
  local scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
  mkdir -p "$scripts"
  cat >"$scripts/generate-secrets.sh" <<'CHILD'
#!/bin/bash
if (( $# != 1 )); then exit 92; fi
printf 'CHILD_GENERATOR:%s\n' "$1"
CHILD
  cat >"$scripts/render-runtime-config.sh" <<'CHILD'
#!/bin/bash
if (( $# != 1 )); then exit 92; fi
printf 'CHILD_RENDERER:%s\n' "$1"
CHILD
  chmod 0555 "$scripts/generate-secrets.sh" "$scripts/render-runtime-config.sh"
  sed "s|$expected_base|$fixture|g" "$generate_source" >"$fixture/generate-wrapper"
  sed "s|$expected_base|$fixture|g" "$render_source" >"$fixture/render-wrapper"
  chmod 0555 "$fixture/generate-wrapper" "$fixture/render-wrapper"
  chmod 0755 "$scripts" "$(dirname -- "$scripts")" \
    "$(dirname -- "$(dirname -- "$scripts")")" \
    "$(dirname -- "$(dirname -- "$(dirname -- "$scripts")")")" \
    "$(dirname -- "$(dirname -- "$(dirname -- "$(dirname -- "$scripts")")")")" \
    "$fixture"
}

root_run() {
  unshare --user --map-root-user -- "$@"
}

nonroot_run() {
  if (( EUID != 0 )); then
    "$@"
  else
    command -v /usr/bin/setpriv >/dev/null 2>&1 || fail 'setpriv is required to exercise the non-root boundary as root'
    /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups -- "$@"
  fi
}

expect_success() {
  local name=$1 wrapper=$2 marker=$3 forbidden output
  if [[ "$marker" == 'CHILD_GENERATOR' ]]; then
    forbidden='CHILD_RENDERER'
  else
    forbidden='CHILD_GENERATOR'
  fi
  if ! output=$(root_run "$wrapper" 2>&1); then
    fail "$name returned failure: $output"
  fi
  [[ "$output" == *"$marker:$fixture/secrets-v1"* ]] || fail "$name did not invoke only its expected child: $output"
  [[ "$output" != *"$forbidden"* ]] || fail "$name invoked the other wrapper's child: $output"
  [[ "$output" != *"$secret_sentinel"* ]] || fail "$name emitted the injected secret sentinel"
  pass "$name"
}

expect_rejection() {
  local name=$1 wrapper=$2 expected=$3 output status
  shift 3
  if output=$(root_run "$wrapper" "$@" 2>&1); then
    fail "$name unexpectedly succeeded: $output"
  else
    status=$?
  fi
  (( status != 0 )) || fail "$name returned a success status"
  [[ "$output" == *"STOP=$expected"* ]] || fail "$name returned the wrong rejection: $output"
  pass "$name"
}

expect_nonroot_rejection() {
  local name=$1 wrapper=$2 output status
  if output=$(nonroot_run "$wrapper" 2>&1); then
    fail "$name unexpectedly succeeded: $output"
  else
    status=$?
  fi
  (( status != 0 )) || fail "$name returned a success status"
  [[ "$output" == *'STOP=ROOT_REQUIRED'* ]] || fail "$name did not reject before staged-path inspection: $output"
  pass "$name"
}

make_render_target() {
  mkdir -m 0700 "$fixture/secrets-v1"
}

new_fixture
expect_success 'generation accepts zero arguments and reaches the generator' "$fixture/generate-wrapper" 'CHILD_GENERATOR'

new_fixture
make_render_target
expect_success 'rendering accepts zero arguments and reaches the renderer' "$fixture/render-wrapper" 'CHILD_RENDERER'

new_fixture
expect_rejection 'generation rejects caller arguments' "$fixture/generate-wrapper" CALLER_ARGUMENTS_FORBIDDEN unexpected
expect_rejection 'rendering rejects caller arguments' "$fixture/render-wrapper" CALLER_ARGUMENTS_FORBIDDEN unexpected

expect_nonroot_rejection 'generation requires root' "$fixture/generate-wrapper"
expect_nonroot_rejection 'rendering requires root' "$fixture/render-wrapper"

new_fixture
scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
rm "$scripts/generate-secrets.sh"
expect_rejection 'generation rejects a missing child' "$fixture/generate-wrapper" STAGED_SCRIPT_NOT_REGULAR

new_fixture
scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
rm "$scripts/render-runtime-config.sh"
mkdir -m 0700 "$fixture/secrets-v1"
expect_rejection 'rendering rejects a missing child' "$fixture/render-wrapper" STAGED_SCRIPT_NOT_REGULAR

new_fixture
scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
mv "$scripts/generate-secrets.sh" "$scripts/generator-real.sh"
ln -s generator-real.sh "$scripts/generate-secrets.sh"
expect_rejection 'generation rejects a child symlink' "$fixture/generate-wrapper" STAGED_SCRIPT_SYMLINK

new_fixture
scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
chmod 0775 "$scripts/generate-secrets.sh"
expect_rejection 'generation rejects a group-writable child' "$fixture/generate-wrapper" STAGED_SCRIPT_WRITABLE

new_fixture
scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
chmod 0757 "$scripts/render-runtime-config.sh"
mkdir -m 0700 "$fixture/secrets-v1"
expect_rejection 'rendering rejects an other-writable child' "$fixture/render-wrapper" STAGED_SCRIPT_WRITABLE

new_fixture
mkdir -m 0700 "$fixture/secrets-v1"
expect_rejection 'generation rejects an existing target' "$fixture/generate-wrapper" SECRET_TARGET_ALREADY_EXISTS

new_fixture
ln -s missing-target "$fixture/secrets-v1"
expect_rejection 'generation rejects a target symlink' "$fixture/generate-wrapper" SECRET_TARGET_ALREADY_EXISTS

new_fixture
expect_rejection 'rendering rejects an absent target' "$fixture/render-wrapper" SECRET_DIRECTORY_NOT_PRESENT

new_fixture
ln -s missing-target "$fixture/secrets-v1"
expect_rejection 'rendering rejects a target symlink' "$fixture/render-wrapper" SECRET_DIRECTORY_SYMLINK

new_fixture
scripts="$fixture/staged/2f69c126ab0098ed2d1323ed33d6bc2761df752f/data-plane/scripts"
attacker="$fixture/attacker.sh"
cat >"$attacker" <<'ATTACKER'
#!/bin/bash
printf 'ATTACKER_CHILD_RAN\n'
ATTACKER
chmod 0555 "$attacker"
output=$(env \
  staged_script="$attacker" secret_target="$fixture/redirected" \
  SCRIPT_PATH="$attacker" TARGET_PATH="$fixture/redirected" \
  EVENTSALES_SCRIPT_PATH="$attacker" EVENTSALES_SECRET_TARGET="$fixture/redirected" \
  BASH_ENV="$attacker" DOCKER_BIN="$attacker" WRAPPER_SECRET_SENTINEL="$secret_sentinel" \
  unshare --user --map-root-user -- "$fixture/generate-wrapper" 2>&1) || fail "generation environment test failed: $output"
[[ "$output" == *"CHILD_GENERATOR:$fixture/secrets-v1"* && "$output" != *'ATTACKER_CHILD_RAN'* ]] || fail "generation environment redirected execution: $output"
[[ "$output" != *"$secret_sentinel"* ]] || fail 'generation emitted the injected secret sentinel'
pass 'generation ignores caller environment path and command redirection'

new_fixture
mkdir -m 0700 "$fixture/secrets-v1"
attacker="$fixture/attacker.sh"
cat >"$attacker" <<'ATTACKER'
#!/bin/bash
printf 'ATTACKER_CHILD_RAN\n'
ATTACKER
chmod 0555 "$attacker"
output=$(env \
  staged_script="$attacker" secret_target="$fixture/redirected" \
  SCRIPT_PATH="$attacker" TARGET_PATH="$fixture/redirected" \
  EVENTSALES_SCRIPT_PATH="$attacker" EVENTSALES_SECRET_TARGET="$fixture/redirected" \
  BASH_ENV="$attacker" DOCKER_BIN="$attacker" WRAPPER_SECRET_SENTINEL="$secret_sentinel" \
  unshare --user --map-root-user -- "$fixture/render-wrapper" 2>&1) || fail "render environment test failed: $output"
[[ "$output" == *"CHILD_RENDERER:$fixture/secrets-v1"* && "$output" != *'ATTACKER_CHILD_RAN'* ]] || fail "render environment redirected execution: $output"
[[ "$output" != *"$secret_sentinel"* ]] || fail 'rendering emitted the injected secret sentinel'
pass 'rendering ignores caller environment path and command redirection'

for wrapper in "$generate_source" "$render_source"; do
  ! grep -Eiq 'docker|podman|compose' "$wrapper" || fail "container command reference found in $wrapper"
  printf_lines=$(grep -Ec '^[[:space:]]*printf[[:space:]]' "$wrapper" || true)
  [[ "$printf_lines" == 1 ]] || fail "unexpected output path found in $wrapper"
  grep -Fqx "  printf 'STOP=%s\\n' \"\$1\" >&2" "$wrapper" || fail "wrapper output is not limited to fixed stop codes: $wrapper"
  ! grep -Eiq 'sha256sum|openssl|base64|secret_value|password_value|token_value' "$wrapper" || fail "secret extraction or hashing reference found in $wrapper"
done
pass 'wrapper source has no Docker reference or secret-output path'

expected_sudoers='agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v2-generate-secrets "", /usr/local/sbin/agent-eventsales-v2-render-config ""'
sudoers_line=$(cat -- "$sudoers_source")
[[ "$sudoers_line" == "$expected_sudoers" ]] || fail 'sudoers does not contain exactly the two zero-argument wrappers'
[[ $(wc -l <"$sudoers_source") -eq 1 ]] || fail 'sudoers contains extra rules or lines'
! grep -Eiq 'ALL[[:space:]]*$|/bin/(ba)?sh|docker|\*' "$sudoers_source" || fail 'sudoers contains a broad command grant'
/usr/sbin/visudo -cf "$sudoers_source" >/dev/null || fail 'visudo rejected the candidate'
pass 'sudoers grants only both exact no-argument wrappers and passes visudo'

printf 'RESULT=PASS\nTESTS_PASSED=%s\n' "$passes"
