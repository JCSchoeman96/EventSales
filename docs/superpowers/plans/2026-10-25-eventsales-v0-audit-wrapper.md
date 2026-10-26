# EventSales V0 audit wrapper implementation plan

> **For agentic workers:** Execute this plan in the isolated `ops/eventsales-v0-audit-wrapper` worktree. Preserve the exact five-file scope and use red-green-refactor for each behavior group.

**Goal:** Add a zero-argument, read-only Docker metadata audit for future EventSales V0 preflight without granting `agentops` Docker-group membership or general-purpose sudo.

**Architecture:** The root-owned installed script has one fixed Docker executable and socket, clears Docker context overrides, and emits bounded line-oriented metadata through fixed formatted Docker queries. The local shell test supplies a PATH-injected fake Docker executable to a temporary test copy; test profiles may lower only fixed output and audit-deadline limits. Production source accepts no override.

**Tech Stack:** Bash, Docker CLI formatted inspection, Python 3 standard library for bounded JSON/CIDR validation where needed, `visudo`, and repository shell validation scripts.

---

## Files and responsibilities

- `deploy/vps/operator/agent-eventsales-v0-audit`: Fixed no-argument Docker metadata queries, strict validation, stable output, and STOP behavior.
- `deploy/vps/operator/agent-eventsales-v0-audit.sudoers`: One root-only command rule with the explicit empty-argument marker.
- `test/scripts/agent_eventsales_v0_audit_test.sh`: PATH-injected fake Docker and assertions for output, exit codes, bounds, and forbidden access.
- `docs/superpowers/plans/2026-10-25-eventsales-v0-audit-wrapper.md`: This implementation record and verification checklist.
- `.github/workflows/ci.yml`: Run the wrapper syntax checks, fake-Docker suite, and sudoers validation in the existing required `vps_deploy_contract` job.

Only these five files may change.

## Task 1: Build the fake-Docker test harness with the first failing case

- [x] Add a Bash test runner with an isolated temporary directory, fake Docker executable, fixture selection, output assertions, and cleanup trap.
- [x] Make a temporary test copy of the wrapper by replacing the fixed `/usr/bin/docker` executable token with `docker`; assert the replacement occurs exactly once. Put the fake executable first in `PATH`. Bound-test profiles may lower fixed numeric limits in the copy only. Never add a test override to the production wrapper.
- [x] Add the zero-argument header and argument-rejection tests first.
- [x] Run `bash test/scripts/agent_eventsales_v0_audit_test.sh arguments`; confirm it fails because the wrapper file does not exist.

## Task 2: Implement the fixed command boundary and pass argument tests

- [x] Add the Bash wrapper with `set -euo pipefail`, zero-argument enforcement, fixed Docker path/socket, sanitized Docker environment, safe headers, and stable STOP/exit behavior.
- [x] Add a fake that records every Docker invocation and returns one healthy D0 fixture.
- [x] Run the focused argument and header cases. Confirm invalid arguments cause no Docker invocation.

## Task 3: Add D0 service, health, and restart tests before their implementation

- [x] Add failing fixtures for missing, duplicate, and unexpected services, stopped containers, missing/unhealthy health, and nonzero restart count.
- [x] Run the D0 cases and record the expected STOP codes.
- [x] Implement filtered container listing and fixed formatted inspection of project/service/name/image/state/health/restart count. Emit records in stable order and omit IDs.
- [x] Rerun D0 cases and confirm each expected STOP and the healthy exact three-service pass.

## Task 4: Add network and default-pool tests before their implementation

- [x] Add failing fixtures for two D0 networks, local bridge networks, multiple IPv4 subnets, IPv6-only/no-IPv4 networks, invalid and duplicate records, and the 128-network/16-IPAM limits.
- [x] Add custom DefaultAddressPools, empty custom pools, absent field, malformed pool, and 32-pool-bound fixtures. The empty custom list must emit the wrapper-spec built-in pool rows. Feature detection must not use a Docker server-version allowlist.
- [x] Run these cases and confirm failure for missing implementation.
- [x] Implement fixed formatted network queries, subnet validation, Docker info field feature detection, built-in fallback, count checks, exact D0 network count, and production network presence checks.
- [x] Rerun the network and pool cases.

## Task 5: Add volume and future-production absence tests before their implementation

- [x] Add failing cases for exactly one and extra D0 volumes, eventsales-prod/eventsales-app container labels including stopped containers, both exact production networks, and the exact production volume.
- [x] Implement fixed volume metadata queries for D0 and exact target names. Check Compose project labels across containers, networks, and volumes. Report presence and STOP without inspecting runtime content.
- [x] Rerun these cases and confirm no mountpoint or filesystem path is emitted.

## Task 6: Add output and secret-boundary tests before hardening

- [x] Add fake fields containing secret, environment, argv, command, endpoint, MAC, mountpoint, and log sentinels. Assert none appear in stdout or stderr.
- [x] Add all object-count, line-size, total-output-size, malformed-field, command-failure, missing-Docker, and Docker-info-failure cases.
- [x] Implement bounded output checks and safe-only error reporting. Ensure the fake records only the approved read verbs and rejects every prohibited mutation verb, `exec`, raw inspect, and unformatted inspect.
- [x] Run the full fake-Docker suite and confirm every case passes with deterministic output and exit status.

## Task 7: Add and validate the sudoers candidate

- [x] Create the single rule `agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v0-audit ""`.
- [x] Run `visudo -cf deploy/vps/operator/agent-eventsales-v0-audit.sudoers` when `visudo` exists. If unavailable, record that fact without installing it.

## Task 8: Run required repository checks

- [x] Run `bash test/scripts/agent_eventsales_v0_audit_test.sh`.
- [x] Run `bash -n deploy/vps/operator/agent-eventsales-v0-audit` and `bash -n test/scripts/agent_eventsales_v0_audit_test.sh`.
- [x] Run `git diff --check`.
- [x] Run `bash scripts/check_vps_deploy_contract.sh`.
- [x] Run `bash scripts/local_ci.sh` through the repository-owned lifecycle. Stop if any required check fails; do not weaken or bypass a gate.
- [x] Confirm the changed path list contains only the five files above and verify that no Docker or VPS contact occurred.


## Verification record

- Offline CI reused the primary checkout's `deps/` after matching `mix.lock` SHA-256 values; build output stayed in this worktree.
- `bash scripts/local_ci.sh`: PASS — 3,067 tests, 0 failures, 1 excluded; Credo, Sobelow, and Dialyzer passed.
- The fake-Docker suite, Bash syntax checks, `visudo`, and the VPS deployment contract checker passed.


## Task 9: Freeze and publish for review

- [x] Compute SHA-256 for the wrapper and sudoers candidate.
- [x] Create a signed commit containing only the five authorized files.
- [x] Push `ops/eventsales-v0-audit-wrapper` and open a DRAFT PR against `main`.
- [x] Register the PR with the current T3 thread and update the matching Linear issue.
- [x] Report the commit, tree, test results, hashes, PR URL, and the unchanged no-VPS/no-install boundary. Do not merge or install.

## Acceptance checklist

- [x] `origin/main` remained `460e7ab1c231167d89e6b75916768829d094dafd` before worktree creation.
- [x] Fake-Docker tests prove the service, network, pool, volume, absence, bounds, secret-output, and mutation-verb contracts.
- [x] Empty custom address pools use the pinned built-in IPv4 pool list; unsupported field access fails closed.
- [x] The production wrapper has no Docker path, context, socket, object, filter, or format input from callers.
- [x] Exactly five files changed; commits are signed; PR is draft; VPS connection and wrapper installation remain absent.
