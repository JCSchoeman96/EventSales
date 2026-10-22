# EventSales D1 R3.4 PgBouncer Health Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, test and publish the approved minimal health-enabled PgBouncer image without widening the frozen runtime.

**Spec:** `docs/superpowers/specs/2026-10-22-d1-r3-4-pgbouncer-health-image-design.md`

**Architecture:** Add one static std-only Rust executable to the frozen DHI PgBouncer base. Accept only the initial PostgreSQL R/10 challenge containing SCRAM-SHA-256. Publish a separately versioned image to GHCR, with no deployment.

**Tech Stack:** Direct rustc, musl x86_64, Docker/BuildKit, Bash host proof script, GitHub Actions and GHCR. No Cargo dependencies or runtime libraries.

**Authority:** The design was accepted at `640f47c316337dfdc91fa28e6fb62ba8178e2bdc`, tree `db55993a31a986a652a620075c9a6c3c5e7ddb26`. The planning branch starts exactly there. Remote main was verified as `d96089d71a9cd7f2f4f8cd46d36b626ee390d6e0` before worktree creation.

**Status:** IMPLEMENTATION_PLANNED, pending plan review. Plan acceptance and implementation authorization remain separate gates. This document authorizes no compilation, image build, registry credential inspection, workflow execution, publication, merge, or VPS mutation.

## Global Constraints

```text
BASE=dhi.io/pgbouncer:1.26.1-debian13@sha256:78fe21ad5b7c1ab497e9828eea9b951f9d6a58eb638946ddc61ef1f99737f1b1
BUILDER=rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9
PLATFORM=linux/amd64
RUST_TARGET=x86_64-unknown-linux-musl
EXTERNAL_RUST_CRATES=0
RUNTIME_SHARED_LIBRARIES=0
FINAL_ADDED_EXECUTABLES=1
MAX_BINARY_SIZE=2097152 bytes (2 MiB)
USER=65532
ENTRYPOINT=["pgbouncer"]
CMD=["/etc/pgbouncer/pgbouncer.ini"]
BACKEND_POSTGRES_FOR_HEALTH_PROOF=NO
PRODUCTION_SECRETS=NO
PUBLICATION_OR_DEPLOYMENT=NO until its explicit gate
```

Keep the accepted design and frozen runtime unchanged. Do not install packages or access mutable package repositories during the pinned image build. Do not add production credentials to local fixtures, the image, build arguments, workflow output, or artifacts.

## Review Focus

1. A slow or fragmented peer must not extend the total I/O deadline. Task 1, Steps 6–8, must test a peer that drips bytes and prove the two-second connect/write/read budget expires.
2. Malformed or boundary PostgreSQL frames must fail closed without panic or allocation abuse. Task 1, Steps 4–5, must cover truncated headers and bodies, invalid lengths, the 4096-byte ceiling, and malformed message types.
3. SASL mechanism parsing must accept the complete `SCRAM-SHA-256` name only. Task 1, Steps 4–5, must test exact match, prefix/suffix lookalikes, list termination, and valid lists with other mechanisms.
4. DHI registry credentials must not propagate into image layers, build arguments, or artifacts. Task 5, Steps 2–3 and 6, must verify login-only use and reject credential propagation through build inputs or outputs.
5. The published digest, source, provenance, SBOM, and runtime invariants must be checked independently. Task 5, Step 5, and Task 6, Steps 5–7, must verify the exact published digest, source SHA, attestations, and the static and integration image checks.

## Scope and fixed inputs

```text
BASE=dhi.io/pgbouncer:1.26.1-debian13@sha256:78fe21ad5b7c1ab497e9828eea9b951f9d6a58eb638946ddc61ef1f99737f1b1
BUILDER=rust:1-alpine3.24@sha256:3ea887915f261f273d6a24efdfdb92665dee12199923e57870453644fe4ae5c9
PLATFORM=linux/amd64
RUST_TARGET=x86_64-unknown-linux-musl
IMAGE=ghcr.io/jcschoeman96/eventsales-pgbouncer
PROBE=/usr/local/bin/eventsales-pgbouncer-healthcheck
```

Use the dedicated branch `feat/d1-r3-4-pgbouncer-health-image` and worktree `.worktrees/d1-r3-4-pgbouncer-health-image`. Preserve the R4.1 branch and worktree. Do not edit the existing application Dockerfile/workflow, canonical D1 documents, deployment Compose, or R4.4 scripts.

Health proves listener availability, PostgreSQL v3 startup parsing, the SCRAM client-authentication path, and advertisement of SCRAM-SHA-256. It does not prove username existence, auth-file completeness, password correctness, successful authentication, backend availability, database existence, pool acquisition, pooling, prepared statements, backend identity, or SQL execution. These stronger proofs remain R4.4 responsibilities.

Production invocation remains `eventsales-pgbouncer-healthcheck 127.0.0.1 6432 eventsales_runtime`. The supplied username is generic input and not a secret. Add no dedicated health identity. Unknown-user behavior has no health PASS/FAIL requirement and must not drive implementation changes.

## File and interface map

All implementation paths below are future work, not files created by this planning gate.

| File | Responsibility |
| --- | --- |
| `deploy/vps/data-plane/pgbouncer-image/eventsales_pgbouncer_healthcheck.rs` | Probe and inline `#[cfg(test)]` unit/socket tests; zero external crates. |
| `deploy/vps/data-plane/pgbouncer-image/Dockerfile` | Pinned builder and base, static verification stage, one-executable final delta. |
| `deploy/vps/data-plane/pgbouncer-image/prove-image.sh` | Host-side build, static filesystem/config verification, and temporary integration proof. |
| `.github/workflows/event-sales-pgbouncer-image.yml` | Dedicated guarded publication and digest metadata. |

Freeze the proof interface as `bash deploy/vps/data-plane/pgbouncer-image/prove-image.sh <mode> [image-reference]`. Modes are `unit`, `build`, `static`, `integration`, `self-test`, and `all`. `self-test` runs checker rejection fixtures without an image argument. `unit` uses the pinned builder. `build` builds and records the local image ID. `static` and `integration` require a reference, resolve it once to an immutable image ID, and use that ID throughout. `all` runs unit, build, static, and integration in order against that one built image ID. Exit zero only if every requested assertion passes. No mode publishes or deploys.

Use local tag `eventsales-pgbouncer:r3-4-local` only as a build handle, never deployment authority. Store proof output in a unique temporary directory. Print assertions and non-secret image IDs only. Preserve failed fixtures/logs for review; successful cleanup must remove only resources owned by that proof run. Never prune build cache or touch shared PostgreSQL/Redis, D0, or production resources.

## Task 1: Permanent Rust health probe

**Create/test:** `deploy/vps/data-plane/pgbouncer-image/eventsales_pgbouncer_healthcheck.rs`.

- [ ] **Step 1: Add inline serialization and CLI tests first.** Assert big-endian startup length and protocol constant `196608`, exactly one `user` key/value pair, NUL termination, and no database, application_name, options, or extra packet. Test a synthetic username, missing/extra CLI arguments, invalid port, and embedded NUL rejection. Test numeric host parsing: accept `127.0.0.1` and `::1` when usable, and reject `example.invalid` before any DNS lookup or socket creation. The CLI is exactly `<host> <port> <username>`.
- [ ] **Step 2: Run the failing tests with direct rustc.** Use the pinned builder, mount only the image-source directory read-only at `/src`, disable networking, and place test binaries in container `/tmp`. Run `rustc --edition=2021 --test --target x86_64-unknown-linux-musl /src/eventsales_pgbouncer_healthcheck.rs -o /tmp/probe-tests`, then `/tmp/probe-tests`. Expected initial failure must identify missing serialization behavior, not a toolchain/setup fault. No local compiler substitution.
- [ ] **Step 3: Implement serialization only, then rerun.** Expected serialization tests pass. Retain a single source file and std only.
- [ ] **Step 4: Add failing response-parser tests.** Cover every row below. Construct raw frame bytes, including partial reads; do not test only already-decoded values. Include a `u32::MAX` declared length and assert the parser rejects it from the header without allocating or waiting for the declared body.

| Case | Required result |
| --- | --- |
| R, code 10, exact SCRAM-SHA-256 mechanism | Healthy |
| Empty EOF or non-PostgreSQL bytes | Unhealthy |
| Truncated 5-byte header | Unhealthy |
| Length smaller than 4 | Unhealthy |
| Length greater than 4096 | Unhealthy |
| Truncated body | Unhealthy |
| Codes 0, 3, 5 | Unhealthy |
| Code 10 without exact SCRAM-SHA-256 | Unhealthy |
| ErrorResponse, including malformed ErrorResponse | Unhealthy |
| NegotiateProtocolVersion or unknown type | Unhealthy |
| Missing SASL-list terminator or unterminated mechanism | Unhealthy |
| SCRAM-SHA-256 prefix/suffix lookalike | Unhealthy |
| Valid list with another mechanism and SCRAM-SHA-256 | Healthy |
| Declared length exactly 4096 | Parse bounded frame, then apply auth predicate |

- [ ] **Step 5: Implement the bounded parser and rerun direct rustc tests.** Read type plus 4-byte big-endian length; length includes its own four bytes but excludes type. Check `4 <= length <= 4096` before allocation, subtraction, or body read. Require four authentication-code bytes. Parse NUL-terminated mechanism names through the final empty terminator, reject trailing junk, and match the complete mechanism name exactly. Any malformed frame is unhealthy. Never accept an auth-code-only match or scan arbitrary bytes for the mechanism substring.
- [ ] **Step 6: Add failing local TCP fixture tests.** Verify refused connection, silent peer, EOF after partial header/body, fragmented valid response, and a peer that drips bytes. Capture client output to prove exactly one StartupMessage and closure after the initial response, with no password, SASL response, second startup, or SQL. Spawn std-only test listeners inside the builder container; no PostgreSQL is needed.
- [ ] **Step 7: Implement numeric-IP-only networking and CLI terminal states.** Parse `<host>` as `std::net::IpAddr`; accept numeric IPv4 and IPv6 literals such as `127.0.0.1` and `::1`, and reject hostnames such as `example.invalid` as a usage failure before any network-resolution attempt. Use a two-second total I/O deadline for connect/write/read, with each blocking call limited to the remaining budget. Fragmented reads must not reset the budget. DNS resolution is not part of R3.4. Use a five-second outer subprocess watchdog in tests to catch hangs. Exit 0 only for `HEALTHY`; all connection, timeout, serialization, parsing, and usage failures exit non-zero as `UNHEALTHY`. Avoid panics and raw server-error output.
- [ ] **Step 8: Rerun the complete direct rustc test binary.** Expected all tests pass, including slow-peer timeout tests and no-extra-message checks. No authentication transition or backend connection may exist. Review the source imports to confirm zero external crates. Commit only this source as a signed reviewer-sized checkpoint after focused validation.

## Task 2: Derived image

**Create:** `deploy/vps/data-plane/pgbouncer-image/Dockerfile`.

- [ ] **Step 1: Define the pinned build stages.** Use the exact BUILDER and BASE above, platform linux/amd64. Compile and run inline tests in the builder with direct rustc. Compile release output for `x86_64-unknown-linux-musl`, optimize and strip with rustc. No Cargo, network dependency download, UPX, or runtime compiler.
- [ ] **Step 2: Make static verification a mandatory build dependency.** Use only ELF and static-inspection tooling already present in the exact pinned builder image. Do not run `apk add`, `apt`, package-manager installs, `curl` downloads, or equivalent tool acquisition during the build. Require x86_64, no PT_INTERP, no DT_NEEDED, executable mode, and size at most 2,097,152 bytes. If the pinned builder lacks tooling to prove architecture, PT_INTERP absence, and DT_NEEDED absence, stop with `PINNED_BUILDER_ELF_VERIFIER_UNAVAILABLE` and return the evidence for review. Do not substitute a builder, install tools, or weaken static verification. The final COPY must consume the verified artifact so BuildKit cannot skip verification. Deliberately test a dynamic executable and an oversize fixture against the verifier; both must fail. Do not ship test binaries, tooling, or sources.
- [ ] **Step 3: Define the final stage from the frozen DHI digest.** Add exactly `/usr/local/bin/eventsales-pgbouncer-healthcheck`, mode 0755. Preserve USER `65532`, ENTRYPOINT `["pgbouncer"]`, and CMD `["/etc/pgbouncer/pgbouncer.ini"]`. Do not replace or remove base files or introduce runtime RUN/package installation. OCI source/revision labels may be added as metadata; neither label is a secret.
- [ ] **Step 4: Build locally after implementation authorization.** Run `docker build --platform linux/amd64 -f deploy/vps/data-plane/pgbouncer-image/Dockerfile -t eventsales-pgbouncer:r3-4-local --build-arg SOURCE_URL=https://github.com/JCSchoeman96/EventSales --build-arg VCS_REF="$(git rev-parse HEAD)" deploy/vps/data-plane/pgbouncer-image`. Expected tests and static checks pass. Registry access failure blocks the build; do not substitute a different base or builder.
- [ ] **Step 5: Inspect image configuration and extracted executable.** Require the frozen USER/ENTRYPOINT/CMD and repeat ELF/size checks outside the build. Commit only the Dockerfile after evidence passes. Task 4 will automate the complete delta check.

## Task 3: Production-shaped integration proof

**Create:** `deploy/vps/data-plane/pgbouncer-image/prove-image.sh`.

- [ ] **Step 1: Implement the frozen mode interface and preconditions.** Reject unknown modes/missing image references, verify linux/amd64, resolve the candidate reference to one image ID, and use unique resource names. Implement `unit` and `build` as the exact pinned test/build commands in Tasks 1 and 2. Use strict shell error handling and explicit capture of expected negative exits; a failed positive assertion must never be masked by cleanup.
- [ ] **Step 2: Create synthetic fixtures in a unique temporary directory.** Use a synthetic known auth-file user such as `r3_4_probe_user`, with a fixture-only SCRAM verifier. Never load production secrets. Configure `listen_addr=0.0.0.0`, `listen_port=6432`, `auth_type=scram-sha-256`, and `pool_mode=transaction`, with read-only auth/config mounts and `/tmp` pid/socket locations. Preserve one unrelated synthetic database mapping to an unused, unreachable synthetic backend address and port. The probe sends no database parameter, so this mapping must not cause a backend connection. Do not start a PostgreSQL container or process; the positive proof must record `BACKEND_POSTGRES_STARTED=NO` and `BACKEND_CONNECTION_REQUIRED_FOR_PASS=NO`.
- [ ] **Step 3: Start the candidate under the production hardening envelope.** Use UID/GID 65532:65532, read-only rootfs, 0.5 CPU, 128 MiB, all capabilities dropped, no-new-privileges, and a bounded writable `/tmp` tmpfs. Attach only a unique internal test network, with no host ports or external network. Bound readiness wait to ten seconds and inspect running state and listener logs. Do not use successful authenticated login for readiness.
- [ ] **Step 4: Exercise the real positive and listener-down cases.** Use `docker exec` to invoke the exact candidate executable at `127.0.0.1 6432 r3_4_probe_user`; require `HEALTHY`, R/10/SCRAM-SHA-256, and exit 0. Invoke it against unused port 6499; require `UNHEALTHY` and non-zero exit within the deadline. Inspect fixture logs and resource inventory to confirm no backend PostgreSQL was started or required.
- [ ] **Step 5: Exercise a real non-PostgreSQL listener.** Use the same pinned Rust builder as a temporary test helper, with a std-only fixture listener embedded as test-only code under `#[cfg(test)]` in the existing Rust file. Attach the helper container to the unique internal test network, bind port 6433, emit a fixed HTTP response, and close. Use Docker inspection to obtain the helper container's numeric IP address, then invoke the candidate executable inside the derived image with that numeric IP and port 6433. Require non-zero exit within the deadline. Do not use a Docker DNS name or network alias. Helper code, compiler, and networking tools must never enter the candidate image. No extra permanent fixture source is needed.
- [ ] **Step 6: Verify failure and cleanup behavior.** A failed assertion preserves owned fixtures and non-secret logs for review and exits non-zero. Successful completion cleans only this run's containers/network/temp files, without cache/image pruning. Optional unknown-user evidence is diagnostic only and must not affect PASS/FAIL or alter the probe. Run `bash -n deploy/vps/data-plane/pgbouncer-image/prove-image.sh` and `bash deploy/vps/data-plane/pgbouncer-image/prove-image.sh integration eventsales-pgbouncer:r3-4-local`. Expected required assertions pass. Commit this focused proof script after review.

## Task 4: Static image-contract verification

**Modify:** `deploy/vps/data-plane/pgbouncer-image/prove-image.sh`, no redundant checker.

- [ ] **Step 1: Implement `static` using stopped containers and exports.** Resolve the frozen base and candidate image IDs. Create containers without starting them, export both root filesystems, and compare normalized manifests by path, type, mode, ownership, symlink target, file size, and file-content hash. Ignore tar ordering/timestamps only. Require every base entry unchanged, no removal, and exactly one added regular executable at the frozen probe path. Allow no unreviewed added directories or files. Always use the pinned base for comparison, not a mutable local tag.
- [ ] **Step 2: Verify config and executable independently.** Require architecture amd64/linux, USER 65532, original ENTRYPOINT/CMD, and no credential-bearing ENV/labels. Extract the probe and require no ELF interpreter, no DT_NEEDED, and size <= 2 MiB. Filesystem equality plus one static executable must establish no added shell, package manager, runtime libraries, compiler, network utilities, or source code. Compare inherited base configuration and reject unexpected changes beyond approved OCI labels. Do not delegate these checks to the future R4.1 checker.
- [ ] **Step 3: Add deterministic checker self-tests in this script.** Use `self-test` solely for checker tests, with no image argument. Feed temporary manifest/config/ELF fixtures with one removed base file, one replaced file, an extra library, wrong USER, wrong ENTRYPOINT/CMD, dynamic ELF, and oversize binary. Each must fail, while the permitted one-executable delta passes. All unknown modes must fail.
- [ ] **Step 4: Run `bash deploy/vps/data-plane/pgbouncer-image/prove-image.sh self-test` and `bash deploy/vps/data-plane/pgbouncer-image/prove-image.sh static eventsales-pgbouncer:r3-4-local`.** Expected all positive and deliberate rejection assertions pass. Record immutable candidate ID and proof results, never credential values. Commit only the checker extension.

## Task 5: Dedicated GHCR publication workflow

**Create:** `.github/workflows/event-sales-pgbouncer-image.yml`. Read `.github/workflows/event-sales-image.yml` as the publication pattern; leave it unchanged.

- [ ] **Step 1: Define publication guards and permissions.** Trigger only main push and workflow_dispatch. Reject dispatch outside refs/heads/main. Use `contents: read` and `packages: write`, linux/amd64, and image namespace `ghcr.io/jcschoeman96/eventsales-pgbouncer`. Mirror existing action major versions and tag guard. Generate `sha-<40hex>` from the exact full source commit. Before pushing, reject an existing SHA tag rather than overwrite it, including manual reruns; reject an already-used optional human tag as well. Disable latest. Optional human tags must satisfy the existing validation, normalize case, and reject latest and the reserved SHA-tag namespace. No PR event may publish.
- [ ] **Step 2: Add fail-closed DHI credential preflight and login before any BuildKit build.** Require non-empty GitHub repository variable `${{ vars.DHI_USERNAME }}` and secret `${{ secrets.DHI_PAT }}` through step environment. Check presence without printing values, lengths, hashes, or expanding secrets into shell text. Log in with `docker/login-action@v4`, registry `dhi.io`, username `${{ vars.DHI_USERNAME }}`, password `${{ secrets.DHI_PAT }}`. Missing configuration or denied login/base access must stop publication, with no alternate base. An authorized credential is an external publication prerequisite, not something to create or inspect during planning.
- [ ] **Step 3: Keep credential boundaries explicit.** Never read or reuse `~/.config/symphony/providers.env` in CI. DHI_PAT is a build-time registry credential only, not a production runtime secret. Never pass it as a build-arg, bake it into a layer, or write it to logs, labels, provenance, SBOM, or artifacts. Use action-managed registry authentication, not COPY of Docker config into the build context.
- [ ] **Step 4: Add GHCR login and pre-publication proof.** Use GITHUB_TOKEN for GHCR, then Buildx. Run the proof script `all` before the push step, so unit, static and real integration failures block publication. Build and push the dedicated Dockerfile/context with the same frozen inputs. Enable BuildKit `provenance: mode=max` and `sbom: true`. Pass only non-secret SOURCE_URL and VCS_REF for OCI source/revision labels.
- [ ] **Step 5: Record digest metadata and recheck the published artifact.** Validate source SHA as 40 lowercase hex and digest as sha256 plus 64 lowercase hex. Upload `eventsales-pgbouncer-image-metadata` with source_sha, image, digest, and digest-qualified reference, following existing artifact retention and summary format. Pull that exact digest and run `static` and `integration` against it; never verify by tag alone. Failure leaves publication acceptance blocked even if bytes already reached GHCR. No deployment step is permitted.
- [ ] **Step 6: Validate without publication during development.** Run `actionlint .github/workflows/event-sales-pgbouncer-image.yml`, inspect parsed trigger/permissions/action inputs, and review missing/unauthorized DHI, non-main dispatch, reserved human tag, failed proof, and invalid digest paths. Add static workflow assertions that DHI credentials are consumed only by the `dhi.io` login action and do not appear in build arguments, Dockerfile build inputs, logs, or artifacts. Use synthetic values for static checks; do not trigger a publication run or inspect GitHub secrets before separate authorization. Commit only the new workflow after review.

## Task 6: Whole R3.4 verification and publication acceptance

**Files:** No new implementation files. Review the four implementation files above and the approved spec. Keep proof evidence outside tracked source unless separately requested.

- [ ] **Step 1: Run complete local proof.** Run `bash -n deploy/vps/data-plane/pgbouncer-image/prove-image.sh`, script `self-test`, then script `all`. Require Rust tests, every malformed-frame case, serialization/no-extra-message proof, bounded timeouts, static ELF/size proof, exact filesystem delta, preserved image config, inspected hardening controls, and real temporary PgBouncer positive/negative proof. Verify no backend PostgreSQL and no proof resources left after success.
- [ ] **Step 2: Review workflow and repository checks.** Run actionlint on the dedicated workflow, `git diff --check`, and `mix quality.fast` as required at slice completion. Before meaningful merge/review run `bash scripts/local_ci.sh` with the canonical local test environment. If quality.ci is required by policy, use `bash scripts/dev_local.sh quality-ci`, never raw quality.ci against shared TEST. Report failures and stop; do not change unrelated application code to make this slice pass. No application runtime or database is required by the image proof itself.
- [ ] **Step 3: Review the exact implementation diff.** Require only the four planned implementation files unless review explicitly authorizes a narrow adjustment. Confirm unchanged DHI/builder digests, zero crates/runtime dependencies, no dedicated identity, no health authentication claim, no local secret reads, no app workflow edits, and no R4.1 Compose/VPS work. Obtain implementation review acceptance before merge. Create coherent signed checkpoints; do not rewrite shared history.
- [ ] **Step 4: Stop at the pre-merge gate.** Report checks and immutable local image ID. Merge and publication require the applicable explicit authority; this plan alone does not authorize them. No PR is created by the P0 authoring task.
- [ ] **Step 5: After authorized merge, identify publication authority.** Record accepted merged main SHA and workflow run for that exact SHA. Require a successful dedicated workflow, captured published digest, source/revision label match, and available BuildKit provenance mode=max plus SBOM attestations tied to that digest and SHA. A successful build without attestations is insufficient.
- [ ] **Step 6: Independently verify the published digest.** Pull `ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:<verified-64-hex-digest>` using the digest captured in Step 5. The angle-bracket expression describes a required verified input, not a deployable literal. Run script `static` and `integration` against that exact digest, verify one-executable delta against the frozen base, and review provenance/SBOM and final runtime invariants independently of the publisher's summary. Reject digest/source mismatches or invariant failures. Do not replace R4.1's raw digest yet.
- [ ] **Step 7: Report the publication gate and stop.** Only after accepted review, merge, exact-SHA publication success, attestation checks, and independent digest/runtime verification may explicit R4.1 resume authorization be considered. Real client authentication, auth-file correctness, backend identity, transaction pooling, prepared statements, and SQL remain R4.4 work.

## Lifecycle and failure handling

```text
DESIGN_APPROVED
  -> IMPLEMENTATION_PLANNED
  -> PLAN_APPROVED
  -> IMPLEMENTATION_AUTHORIZED
  -> IMPLEMENTED
  -> REVIEW_ACCEPTED
  -> MERGED
  -> IMAGE_PUBLISHED
  -> DIGEST_VERIFIED
  -> R4_1_RESUME_AUTHORIZED
```

`IMPLEMENTATION_BLOCKED`, `REVIEW_REJECTED`, `PUBLICATION_BLOCKED`, and `DIGEST_REJECTED` are terminal until explicit review resolves the failure. No failed gate silently advances. Preserve non-secret failure evidence; do not blindly repeat a failing operation twice without new evidence.

Stop if architecture, dependencies, dedicated identity, base/builder digest, accepted health semantics, or D1 scope must change. Stop before any production/VPS mutation. The R4.1 and R4.2 authorization flags remain NO.

## Planning self-review

- Spec coverage: Tasks 1 and 3 implement protocol and semantic boundaries; Tasks 2 and 4 cover builder/runtime delta and hardening; Tasks 5 and 6 cover publication, attestations, independent verification, and blocked R4.1 transition.
- Step granularity: Tests precede parser/network implementation, image build precedes image proof, and each task has a focused review/checkpoint. No single task combines the probe, image, proof and workflow implementation.
- Interface/name consistency: One Rust source, one Dockerfile, one proof script with named modes, one dedicated workflow, one GHCR namespace. All candidate checks resolve one immutable image ID; publication acceptance uses the published digest.
- Review focus: Total timeout budget, partial/truncated frames, strict SCRAM-list termination, DHI CI login ordering, no credential propagation, and published-image verification are explicit requirements.
- Proportionality: No Cargo scaffold, extra fixture source, sidecar deployment, runtime tools, R4.1 checker responsibility, architecture rewrite, or new spike. The plan contains no Rust/Docker/workflow implementation code.

```text
R3_4_DESIGN_ACCEPTED=YES
R3_4_IMPLEMENTATION_PLAN_AUTHORING=AUTHORIZED
R3_4_IMPLEMENTATION_PLAN_ACCEPTED=NO
R3_4_IMPLEMENTATION_AUTHORIZED=NO
R4_1_RESUME_AUTHORIZED=NO
R4_2_AUTHORIZED=NO
VPS_MUTATION_AUTHORIZED=NO
```
