# EventSales V3 PostgreSQL recovery implementation plan

## Scope

Implement the reviewed design in `docs/superpowers/specs/2026-10-29-v3-postgres-recovery-design.md`. Do not begin implementation until the design is reviewed.

This implementation adds a separate recovery wrapper, sudoers fragment, and fake-Docker test. It does not install the wrapper, contact the VPS, run Docker, or use sudo. Installation and execution need separate authorization.

## Exact files

Add:

```text
deploy/vps/operator/agent-eventsales-v3-recover-postgres
deploy/vps/operator/agent-eventsales-v3-recover-postgres.sudoers
test/scripts/agent_eventsales_v3_recover_postgres_test.sh
```

Update only as needed to register and pin the new authority:

```text
test/scripts/agent_eventsales_v3_wrappers_test.sh
scripts/check_vps_deploy_contract.sh
.github/workflows/ci.yml
```

Do not edit:

```text
deploy/vps/operator/agent-eventsales-v3-start-postgres
deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres
deploy/vps/operator/agent-eventsales-v3-provision-networks
deploy/vps/operator/agent-eventsales-v3.sudoers
deploy/vps/operator/agent-eventsales-v3-audit-state
deploy/vps/operator/agent-eventsales-v3-audit-state.sudoers
```

## Baseline gates

Before editing, require both `HEAD` and `origin/main` to remain:

```text
SHA=86c023afb9b5f18c8c8230e1e739453c4c722c30
TREE=705facd5f932a1dd7fa107514b9cc14a0c377d0b
```

Preserve these hashes exactly:

```text
provision=4ede4ad5ae0696ee605bd890e3ced9a18d8d5ac4c7a11992325823de7e5cdad3
start=b054b6e97da5e8455615534273168fe4322ce7f6800a5b6486892027df33b567
bootstrap=b763431776faf81a8cc84b61c494b3ed22bb8bf732962306973878e83fae79ab
v3 sudoers=8575c6c1e85d111bb78b360b8e03f2c9f6e6a1dfccc5fbc0273003a354bc51d3
audit sudoers=52c7e97b51338bcaa34ebe74ed5731055bf3dfa36000af3fa826315ce5a2d974
```

Require the corrected Compose source hash `3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218`. Stop for review on any drift; do not refresh pins automatically.

## TDD sequence

1. Add `test/scripts/agent_eventsales_v3_recover_postgres_test.sh` first. Build isolated fixtures for the trusted stage, secrets, networks, volume identity, production containers, D0 IDs, lock, and consumed marker. Use fake Docker that records calls and rejects operations outside the allowlist.
2. Add pre-mutation rejection tests. Each test asserts the expected STOP and proves `CONTAINER_REMOVE_NOT_CALLED`, `COMPOSE_UP_NOT_CALLED`, `VOLUME_DELETE_NOT_CALLED`, and `D0_MUTATION_NOT_CALLED`.
3. Add mutation failure tests. A failed removal must block Compose. A Compose failure or post-removal mismatch must not retry, roll back, delete a volume, or start another service. Verify the consumed marker remains once recovery is authorized.
4. Add a success test asserting exactly one `docker rm eventsales-prod-postgres-1`, one Compose `up -d --no-deps postgres`, no bootstrap, no other Docker mutations, unchanged volume/network/D0 identities, and exact safe output.
5. Implement `deploy/vps/operator/agent-eventsales-v3-recover-postgres` until the new suite passes. Keep arguments, paths, names, hashes, project, and options fixed. Suppress raw Docker output.
6. Add the one-line sudoers fragment. Test its exact zero-argument command, absence of other rules/wildcards, and syntax with local `visudo`. VPS-native `visudo` remains required before future installation.
7. Register the new suite with the existing V3 wrapper regression and CI path. Extend the deploy contract only for source-level checks the wrapper suite does not cover.

## Pre-mutation test matrix

Every case must prove no remove and no Compose call.

| Area | Cases |
| --- | --- |
| Invocation and one-shot | Caller arguments; non-root; lock busy; consumed marker present |
| Stage | Symlink or missing required directory; ownership drift; group/other write bit; Compose symlink or non-regular file; Compose owner, mode, or SHA mismatch |
| Secrets | Secret directory type/owner/mode mismatch; every required file missing, symlinked, non-regular, wrong owner/group/mode/size |
| Networks | Data or edge network missing; wrong name, driver, internal flag, or ID |
| Volume | Missing; wrong name/driver/scope; missing/symlinked mountpoint; changed fingerprint; failed-container volume absent, extra, or wrong destination |
| Inventory | Unexpected project or `eventsales-prod*` container; PostgreSQL missing |
| Failed PostgreSQL | Running, restarting, wrong status, exit code, restart count, OOM flag, image, historical command, memory, or CPU |
| Attachments | Wrong/extra volume; wrong network; published port; unexpected mount |
| D0 | Count mismatch; non-exited, running, or restarting container; invalid IDs |

## Mutation-path test matrix

Every case must prove no second remove, no second Compose call, no volume deletion, and no D0 mutation.

| Failure point | Cases |
| --- | --- |
| Removal | `docker rm` failure consumes authority and prevents Compose |
| Recreation | Compose failure is called once; recreated container missing |
| Runtime identity | Wrong image; wrong command; leading `postgres`; resource mismatch; nonzero restart count; OOM killed |
| Runtime state | Exited; dead; unhealthy; inspect error; bounded health timeout |
| Attachments | Volume mismatch or fingerprint change; wrong/extra network; published port; unexpected mount |
| Isolation | Extra production container; changed D0 IDs; D0 running, restarting, or otherwise changed |

Use a shortened timeout in the test copy for the timeout case. Keep production timeout fixed at 120 seconds.

## Success assertions

The fake-Docker success case proves:

```text
docker rm eventsales-prod-postgres-1: once, no flags
docker compose ... up -d --no-deps postgres: once
bootstrap calls: zero
network mutations: zero
volume mutations: zero
PgBouncer, Redis, app starts: zero
D0 mutations: zero
volume fingerprint unchanged: yes
network IDs unchanged: yes
same three stopped D0 IDs: yes
stdout: exact safe success fields from the design
```

## Existing regressions

After implementation, run:

```text
bash test/scripts/agent_eventsales_v3_recover_postgres_test.sh
bash test/scripts/agent_eventsales_v3_wrappers_test.sh
bash test/scripts/agent_eventsales_v3_audit_state_test.sh
bash scripts/check_vps_deploy_contract.sh
```

The new test must not contact Docker or the VPS. Existing tests use their fixtures/fakes. Recheck all five historical hashes after testing.

## Installation lifecycle after review

Installation is a separate task. Transfer only reviewed candidates and independently verify their hashes on the VPS. Run VPS-native `/usr/sbin/visudo -cf` against the candidate sudoers fragment before activation. Install exact wrapper bytes as `root:root`, mode `0755`, and the fragment as `root:root`, mode `0440`. Verify hashes, file types, ownership, modes, and `sudo -n -l`. Do not modify historical sudoers or create/clear the consumed marker during installation.

## Execution lifecycle after separate authorization

Execution is outside implementation. A later explicit instruction must authorize one zero-argument invocation. Establish exclusive Docker maintenance first. Invoke once, capture safe output and status, and stop after success or STOP. Do not run bootstrap, another wrapper, direct Docker commands, or retry recovery.

## Completion boundary

Implementation is complete when the new fake-Docker suite and listed regressions pass, historical hashes remain unchanged, the new sudoers rule is exact, and the diff contains only the new authority and necessary test/contract registration. Do not install or execute the wrapper during implementation.
