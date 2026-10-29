# EventSales V3 PostgreSQL recovery implementation plan

## Scope and authorization boundary

Implement only after review of the design and a separate implementation authorization. The authorization must supply the exact post-merge baseline and reviewed document identities below. Implementation adds a recovery wrapper, its zero-argument sudoers fragment, and fake-Docker tests. It does not install the wrapper, access the VPS, use sudo, run production Docker, or execute recovery. Installation and execution require separate authorization.

## Implementation authority preflight

The design context is fixed:

    DESIGN_BASE_SHA=86c023afb9b5f18c8c8230e1e739453c4c722c30
    DESIGN_BASE_TREE=705facd5f932a1dd7fa107514b9cc14a0c377d0b
    REVIEWED_DESIGN_HEAD=<final signed PR #348 reviewed head>
    IMPLEMENTATION_BASE_SHA=<separately supplied after PR #348 merge>
    IMPLEMENTATION_BASE_TREE=<separately supplied after PR #348 merge>

Before implementation, the authorization must supply the final reviewed head and blob IDs for both reviewed documents, plus the exact implementation base SHA and tree. The preflight requires:

1. Worktree HEAD and origin/main both equal the supplied IMPLEMENTATION_BASE_SHA and IMPLEMENTATION_BASE_TREE.
2. The final reviewed PR #348 commit is an ancestor of the implementation base. The merge must preserve that commit in ancestry. A squash merge that omits the reviewed commit does not satisfy the guard.
3. The design and plan blobs at the reviewed commit equal the separately supplied blob IDs.
4. c9ce0f9239123a6e58f66fde0b5a1e60238bb107 is an ancestor of the implementation base.
5. No path, content, or mode under deploy/vps/data-plane/** differs between that c9ce commit and the implementation base.
6. deploy/vps/data-plane/compose.yaml still has SHA-256 3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218.

These are separate authorities. Never infer or refresh the implementation SHA/tree, reviewed commit, document blob IDs, source ancestry, data-plane comparison, or Compose pin. Any mismatch is a STOP.

## Future implementation files

Add:

    deploy/vps/operator/agent-eventsales-v3-recover-postgres
    deploy/vps/operator/agent-eventsales-v3-recover-postgres.sudoers
    test/scripts/agent_eventsales_v3_recover_postgres_test.sh

Update only as required to register and enforce this authority:

    test/scripts/agent_eventsales_v3_wrappers_test.sh
    scripts/check_vps_deploy_contract.sh
    .github/workflows/ci.yml

Do not edit:

    deploy/vps/operator/agent-eventsales-v3-start-postgres
    deploy/vps/operator/agent-eventsales-v3-bootstrap-postgres
    deploy/vps/operator/agent-eventsales-v3-provision-networks
    deploy/vps/operator/agent-eventsales-v3.sudoers
    deploy/vps/operator/agent-eventsales-v3-audit-state
    deploy/vps/operator/agent-eventsales-v3-audit-state.sudoers

No implementation task may change historical authority or the accepted c9ce data-plane source.

## Task-by-task TDD plan

### Task 1: implement the recovery wrapper behind fake-Docker tests

**Files changed**

    deploy/vps/operator/agent-eventsales-v3-recover-postgres
    test/scripts/agent_eventsales_v3_recover_postgres_test.sh

**Failing tests first**

Create isolated stage, secret, network, volume, production-container, D0, lock, and marker fixtures. Add fake Docker that logs calls and rejects commands outside the reviewed allowlist. Add tests for:

- zero arguments, non-root invocation, fixed environment, unsafe /run metadata, lock symlink, wrong lock owner/mode, and busy lock;
- consumed marker conflicts as directory, file, or symlink, plus marker-creation failure;
- every immutable-stage path, ownership, write-bit, Compose type, symlink, ownership, mode, and hash mismatch;
- secret directory and each required secret metadata mismatch, without reading secret contents;
- data/edge network mismatch, missing or changed volume, invalid mountpoint, and volume fingerprint drift;
- unexpected production inventory, missing or incorrect failed PostgreSQL state, image, historical command, resources, mount, network, and ports;
- D0 count, ID, running, restarting, status, and identity drift;
- invalid failed Docker ID, reinspection drift, and removal of the exact captured failed ID once with no flags;
- exact recovery override content and SHA-256, root:root ownership, directory mode 0700, file mode 0400, no symlink, and use as the second Compose file;
- override creation or validation failure before marker creation; a missing external volume immediately before Compose causing no Compose call and no replacement volume; fingerprint change blocking Compose before invocation and failing after invocation;
- Compose failure with no new container, one new container, and ambiguous identity; failed and changed container IDs; and every listed corrected-runtime or health failure;
- one containment stop of the new ID when it is running or restarting, zero stops when it is already stopped, stop success and verified-stopped state, stop failure, still-running/restarting state, and unresolved identity;
- success with one removal by failed ID, one Compose call, no stop, exact success output, and no bootstrap, migrations, secret regeneration, network/volume changes, other service starts, or D0 mutation.

Every pre-mutation rejection proves:

    docker rm calls=0
    Compose calls=0
    docker stop calls=0
    volume mutations=0
    D0 mutations=0

Every post-Compose failure with the new PostgreSQL object running or restarting proves exactly one stop against NEW_POSTGRES_CONTAINER_ID, no retry, no new-container removal, no volume deletion, no D0 mutation, and a persistent consumed marker. For an already stopped object, prove zero stop calls and verify its stopped state. An ambiguous new-object identity must never trigger a guessed name-based stop and must end as RECOVERY_FAILED_UNCONTAINED.

**Expected RED**

The new suite fails because the wrapper and its preflight, mutation, volume-override, and containment behavior do not exist. Each failure case must check its expected STOP and reject unsafe fake-Docker calls.

**Minimal implementation responsibility**

Implement only the fixed recovery authority described in the design: zero-argument root entry; sanitized environment; safe nonblocking lock; read-only stage, secret, network, volume, container, and D0 guards; persistent one-shot marker created immediately before the first Docker mutation; root-only override created and validated before marker creation and re-hashed before Compose; failed-container capture, ID-format validation, immediate reinspection, and removal by captured ID; one postgres-only Compose invocation with the override second; new-container capture and ID-based validation; one bounded containment stop for a running/restarting new object after failure; bounded 120-second health checking; exact safe output; deterministic STOP states. Never bootstrap, migrate, regenerate secrets, remove storage, mutate networks, or address D0 for mutation.

**Verification command**

    bash test/scripts/agent_eventsales_v3_recover_postgres_test.sh

**Expected GREEN**

The full fake-Docker suite passes. It proves preflight failures do not consume authority; the marker remains after the first Docker mutation; missing external volume cannot be replaced; failed and new containers are addressed by captured IDs; running or restarting invalid PostgreSQL receives one stop attempt; contained and uncontained failures are distinct; success emits only the design's safe fields; and Docker volume/network/D0 mutation counts remain zero.

**STOP conditions**

Stop if any test needs a real Docker daemon, VPS, sudo, production secret, or production-only path; if volume identity or external-volume semantics are unresolved; if containment cannot target only the captured new ID; if a test permits a retry or name-based mutation; or if any test observes volume, network, or D0 mutation.

### Task 2: add the dedicated sudo boundary and repository registration

**Files changed**

    deploy/vps/operator/agent-eventsales-v3-recover-postgres.sudoers
    test/scripts/agent_eventsales_v3_recover_postgres_test.sh
    test/scripts/agent_eventsales_v3_wrappers_test.sh
    scripts/check_vps_deploy_contract.sh
    .github/workflows/ci.yml

**Failing tests first**

Add assertions for the exact zero-argument command, absence of other sudo rules and wildcards, deploy-contract identity, and suite/CI registration. Confirm these assertions fail before adding the fragment or registrations.

**Expected RED**

The sudoers and deploy-contract assertions fail because the new fragment and registrations are absent.

**Minimal implementation responsibility**

Add only:

    agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-recover-postgres ""

Register the new fake-Docker test and source checks. Do not alter historical wrapper or sudoers files. Use local syntax checks where available; installation still requires VPS-native visudo.

**Verification commands**

    bash test/scripts/agent_eventsales_v3_recover_postgres_test.sh
    bash test/scripts/agent_eventsales_v3_wrappers_test.sh
    bash test/scripts/agent_eventsales_v3_audit_state_test.sh
    bash scripts/check_vps_deploy_contract.sh
    git diff --check

**Expected GREEN**

All listed checks pass. The new rule authorizes only the exact zero-argument wrapper. Historical wrapper and sudoers hashes remain unchanged. No VPS or production Docker access occurs.

**STOP conditions**

Stop on historical authority drift, broad or argument-accepting sudo, failed tests, required production access, or changes outside the listed implementation files.

## Required pre-mutation coverage

Every case proves zero rm, Compose, stop, volume mutation, and D0 mutation:

| Area | Required cases |
| --- | --- |
| Invocation and environment | Caller arguments; non-root; unsafe /run metadata |
| Lock and marker | Lock symlink; wrong owner/mode; busy lock; marker as directory, file, or symlink; marker creation failure |
| Immutable stage | Parent/stage symlink; missing path; ownership drift; group/other write bit; Compose symlink/type/owner/write/hash drift |
| Secrets | Secret directory mismatch; every required secret missing, symlinked, non-regular, or wrong owner/group/mode/size |
| Networks | Data or edge network missing or wrong name, driver, internal flag, or identity |
| Volume | Missing; wrong name/driver/scope; invalid mountpoint; fingerprint drift; wrong, missing, or extra failed-container mount or destination |
| Production inventory | Unexpected project/name-filter container; PostgreSQL missing |
| Failed PostgreSQL | Running, restarting, wrong status, exit code, restart count, OOM flag, image, historical command, memory, or CPU |
| Attachments | Wrong/extra volume; unexpected secret mount; wrong network; published port |
| D0 | Count/ID mismatch; non-exited, running, or restarting container; invalid ID |

## Required mutation and containment coverage

Every failure proves no retry, volume deletion, network mutation, or D0 mutation:

| Stage | Required cases |
| --- | --- |
| Removal | Failed rm consumes authority and prevents Compose; exactly the captured validated ID is removed once with no flags |
| Override and volume | Exact content/hash/modes; override passed second; missing volume immediately before Compose means no Compose and no replacement; pre-Compose fingerprint drift blocks Compose; post-Compose fingerprint drift fails |
| Recreation | Compose failure once; missing or ambiguous new object; invalid new ID or ID equal to failed ID |
| Runtime contract | Wrong image/command including leading postgres; resource mismatch; published port; wrong volume/network; nonzero restart count; OOM; extra production container |
| Health | Exited/dead/already-stopped; unhealthy; inspect error; 120-second deadline tested with a shorter test timeout |
| Isolation | Changed D0 IDs/state; changed network or volume identity |
| Containment | For each post-Compose failure with new ID running/restarting, exactly one stop targets NEW_ID. No new-ID rm, retry, volume deletion, or D0 mutation. Marker persists. Verified stopped state yields RECOVERY_FAILED_CONTAINED. Stop failure or remaining running/restarting state yields RECOVERY_FAILED_UNCONTAINED. |

## Success assertions

The fake-Docker success case proves:

    docker rm "$FAILED_POSTGRES_CONTAINER_ID": exactly once, no flags
    Compose up -d --no-deps postgres: exactly once, override is second file
    docker stop calls=0
    bootstrap/migration/secret regeneration calls=0
    network and volume mutations=0
    PgBouncer/Redis/app starts=0
    D0 mutations=0
    volume fingerprint unchanged
    network IDs and three stopped D0 IDs unchanged
    stdout=exact safe success fields from the design

## Historical regressions

After implementation, verify these accepted hashes:

    provision=4ede4ad5ae0696ee605bd890e3ced9a18d8d5ac4c7a11992325823de7e5cdad3
    start=b054b6e97da5e8455615534273168fe4322ce7f6800a5b6486892027df33b567
    bootstrap=b763431776faf81a8cc84b61c494b3ed22bb8bf732962306973878e83fae79ab
    v3 sudoers=8575c6c1e85d111bb78b360b8e03f2c9f6e6a1dfccc5fbc0273003a354bc51d3
    audit sudoers=52c7e97b51338bcaa34ebe74ed5731055bf3dfa36000af3fa826315ce5a2d974

No historical file may change.

## Installation lifecycle after implementation review

Installation is separate and needs separate authorization. Transfer only reviewed candidates, independently verify hashes on the VPS, run VPS-native /usr/sbin/visudo -cf on the candidate sudoers fragment before activation, install the wrapper as root:root mode 0755 and the fragment as root:root mode 0440, then verify hashes, file type, ownership, modes, and exact sudo listing. Do not create or clear the persistent consumed marker during installation.

## Execution lifecycle after separate recovery authorization

Establish the exclusive Docker maintenance interval. Invoke exactly once with the zero-argument sudo rule, capture safe stdout, stderr, and status, then stop. Do not run bootstrap, another wrapper, direct Docker commands, or a second recovery attempt.

## Completion boundary

Implementation is complete only after the new fake-Docker suite and listed historical regressions pass, historical hashes remain exact, the sudo rule is exact, and only listed implementation files changed. No VPS installation or production recovery occurs under this plan.
