# EventSales V3 PostgreSQL recovery design

## Status

Design for review only. It does not authorize implementation, installation, or recovery. No wrapper has been implemented.

## Goal and non-goals

Design a dedicated, zero-argument, one-shot root wrapper that replaces only the known failed PostgreSQL container with one created from the corrected immutable c9ce stage:

    SOURCE_SHA=c9ce0f9239123a6e58f66fde0b5a1e60238bb107
    STAGE=/root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane
    COMPOSE_SHA256=3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218

The corrected Compose uses the pinned PostgreSQL image, flags-only command, 3 GiB memory limit, 2 CPU limit, the existing named data volume, the internal data network, no published ports, and a health check.

The wrapper will not bootstrap, migrate, regenerate or rerender secrets; start PgBouncer, Redis, EventSales, or D0; mutate networks or volumes; edit historical V3 authorities; retry recovery; roll back to the failed container; or print Docker JSON, secret values, secret hashes, or secret mount source paths.

The wrapper must preserve the already initialized database volume. The existing database contents remain authoritative; attaching the bootstrap secret does not reinitialize the database or change its existing password.

## Authority and implementation baseline

The design was authored against:

    DESIGN_BASE_SHA=86c023afb9b5f18c8c8230e1e739453c4c722c30
    DESIGN_BASE_TREE=705facd5f932a1dd7fa107514b9cc14a0c377d0b
    REVIEWED_DESIGN_HEAD=<final signed PR #348 reviewed head>
    IMPLEMENTATION_BASE_SHA=<supplied after PR #348 merge>
    IMPLEMENTATION_BASE_TREE=<supplied after PR #348 merge>

The design base records the historical source context. It is not the future implementation baseline.

Before implementation, a separate authorization must supply exact implementation-base SHA and tree, final reviewed PR #348 commit SHA, and the reviewed blob identities of both this design and its implementation plan. The implementation preflight must require:

1. The clean implementation worktree and origin/main both equal the supplied IMPLEMENTATION_BASE_SHA and IMPLEMENTATION_BASE_TREE.
2. The final reviewed PR #348 commit is an ancestor of IMPLEMENTATION_BASE_SHA. The merge method must preserve that commit in ancestry; a squash merge that omits it does not satisfy this guard.
3. The design and plan blobs at the reviewed commit have the exact separately supplied blob identities.
4. c9ce0f9239123a6e58f66fde0b5a1e60238bb107 is an ancestor of IMPLEMENTATION_BASE_SHA.
5. deploy/vps/data-plane/** has no content, path, or mode difference between that c9ce source commit and IMPLEMENTATION_BASE_SHA.
6. The corrected Compose file still has SHA-256 3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218.

Any mismatch is a STOP. Never refresh a SHA, tree, blob, source, or Compose pin automatically. The final reviewed head and document blob identities are recorded only after the final signed correction commit exists; they cannot be self-references inside that commit.

## State machine and terminal states

    FAILED_CONTAINED
      | all read-only preconditions pass; persistent marker is created
      v
    RECOVERY_AUTHORIZED
      | exact failed container is re-inspected by captured ID
      v
    REMOVING_FAILED_CONTAINER
      | one docker rm of the validated ID succeeds
      v
    RECREATING
      | one Compose up for postgres only returns
      v
    VALIDATING_RECREATED_CONTAINER
      | new ID and complete runtime contract pass
      v
    HEALTH_CHECKING
      | running, healthy, restart count zero, all invariants hold
      v
    RECOVERED_HEALTHY

    RECREATING / VALIDATING_RECREATED_CONTAINER / HEALTH_CHECKING
      | failure while new PostgreSQL is running or restarting
      v
    CONTAINING_FAILED_RECREATION
      | one bounded docker stop of the captured new ID
      +--> verified stopped: RECOVERY_FAILED_CONTAINED
      +--> stop fails or still running/restarting: RECOVERY_FAILED_UNCONTAINED

A failure after the old container has been removed is terminal. There is no retry, rollback, second Compose call, or restoration of the old container. If Compose fails before creating a new container, or the new container is already stopped, recovery ends as RECOVERY_FAILED_CONTAINED without a stop. Every post-Compose contract or health failure inspects the exact new ID; if that object is running or restarting, the wrapper makes exactly one containment-stop attempt against that ID.

RECOVERY_FAILED_CONTAINED means the newly created PostgreSQL object is absent or verified stopped. RECOVERY_FAILED_UNCONTAINED means the one containment stop failed or the exact new object remains running or restarting. It requires immediate owner intervention. The wrapper emits a deterministic STOP reason in either failure state and retains the consumed marker.

## Entry, environment, lock, and consumed marker

The wrapper starts with:

    #!/bin/bash -p
    set -euo pipefail
    set +x
    umask 077

It rejects all arguments and requires EUID=0. It unsets caller-controlled Docker, Compose, shell startup, and EventSales secret-directory variables, then sets fixed PATH=/usr/sbin:/usr/bin:/sbin:/bin, LC_ALL=C, DOCKER_HOST=unix:///var/run/docker.sock, and EVENTSALES_SECRET_DIR=/root/eventsales-prod/secrets-v1. Docker commands run with a cleared environment and the fixed socket. Paths, container names, network names, hashes, project name, Compose files, and options are constants.

The wrapper takes a nonblocking flock on /run/agent-eventsales-v3-recover-postgres.lock and holds it through final verification. Require /run to be a non-symlink root:root directory with no group/other write bits. If the lock file is absent, create it exclusively as root under umask 077. Then require a non-symlink regular file owned root:root, mode 0600. Reject an unsafe or busy lock before Docker access. Keep the fixed lock inode in place after releasing the lock; unlinking it could allow a waiter to lock a different inode and defeat serialization.

Before any Docker mutation, validate that /root/eventsales-prod/.v3-postgres-recovery-consumed is absent and has no symlink, file, or directory conflict. After all read-only preconditions pass, create this persistent root-owned mode-0700 directory atomically immediately before the first Docker mutation. Marker creation failure stops before Docker. Marker creation consumes authority even if the subsequent removal fails. Never clear or replace the marker. A later invocation stops before Docker.

The wrapper-created private temporary directory holds only the recovery Compose override. A cleanup trap may remove only that exact wrapper-created temporary directory and its override file. It must never remove or alter the consumed marker, fixed lock file, containers, networks, volumes, or D0 resources.

Create and validate the override before creating the consumed marker. If temporary-directory or override creation, metadata validation, content validation, or hashing fails, stop before Docker mutation and leave the marker absent. Re-hash the override again immediately before Compose. This keeps avoidable local preparation failures outside the destructive interval.

The fixed wrapper lock serializes this wrapper. Because other Docker actors do not honor it, an exclusive Docker maintenance interval is also a precondition. No root operator or other agentops session may invoke Docker or historical V3 start, bootstrap, or provision authorities during recovery. If this cannot be established, stop with UNRESOLVED_CONCURRENCY.

## Immutable stage trust checks

Before any Docker mutation, require each path below to be a non-symlink directory owned by uid 0 and gid 0, with no group/other write bits:

    /root
    /root/eventsales-prod
    /root/eventsales-prod/staged
    /root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107
    /root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane

Require compose.yaml to be a non-symlink regular file, root:root, with no write bits, and the exact SHA-256 above. Recheck its hash immediately before Compose. The directory name alone does not establish file identity.

## Secret handling

Require /root/eventsales-prod/secrets-v1 to be a non-symlink root:root directory, mode 0700. Preserve the current V3 start/bootstrap metadata contract:

| File | uid:gid | Mode | Size |
| --- | --- | --- | --- |
| postgres_bootstrap_password | 0:70 | 0440 | 64 |
| eventsales_migrator_password | 0:0 | 0400 | 64 |
| eventsales_runtime_server_password | 0:0 | 0400 | 64 |
| eventsales_runtime_client_password | 0:0 | 0400 | 64 |
| eventsales_backup_password | 0:0 | 0400 | 64 |
| redis_runtime_password | 0:0 | 0400 | 64 |
| redis_stats_password | 0:0 | 0400 | 64 |
| pgbouncer.ini | 0:65532 | 0440 | nonempty |
| pgbouncer_users.txt | 0:65532 | 0440 | nonempty |
| redis-users.acl | 0:65532 | 0440 | nonempty |

Every item is a non-symlink regular file. Check metadata only; never read or print secret contents or hashes. Preserve the rendered-secret checks needed for Compose evaluation. The bootstrap secret remains mounted as expected, but the wrapper never invokes bootstrap.

## Network guards

Before removal, require both existing networks and exact metadata:

    eventsales-prod_eventsales_data: driver=bridge, internal=true
    eventsales-prod_eventsales_edge: driver=bridge, internal=false

Record IDs and recheck identities and metadata after removal and recreation. The postgres service uses the existing data network. The wrapper has no network mutation operation, and Compose must not be allowed to create a replacement data network.

## Volume preservation invariant and recovery-only Compose override

Never call docker volume rm, docker compose down -v, docker system prune, or any equivalent operation. Never pass -v or --volumes to docker rm.

Require eventsales-prod_postgres_data to exist with exact name, local driver, local scope, and a non-symlink mountpoint directory. Capture its mountpoint device/inode fingerprint. Require the failed container to have exactly one volume mount with this name at /var/lib/postgresql.

Immediately before removal, capture the fingerprint. After removal and immediately before Compose, re-inspect the volume and require unchanged metadata and fingerprint. After Compose, require the same volume identity, attachment, and fingerprint. Do not print the mountpoint. Any fingerprint change stops recovery.

The immutable c9ce Compose file remains untouched. Its named-volume declaration is not external, so it alone would allow Compose to create the name if the volume disappeared. Prevent that race with a recovery-only override generated from these exact literal bytes:

    volumes:
      postgres_data:
        external: true
        name: eventsales-prod_postgres_data

The exact bytes include one final newline and have SHA-256:

    RECOVERY_OVERRIDE_SHA256=cc4bc2cee5847d9d24984ccc5521ef81868aeb77456e66b94df62c50685f2e14

The wrapper creates a private root:root temporary directory with mode 0700 and a non-symlink override file owned root:root with mode 0400. The fixed content and SHA-256 are embedded in the wrapper. Re-hash the file immediately before Compose. The override is the second Compose file, after the immutable c9ce file. It changes only the top-level postgres_data declaration and requires the existing external volume. Compose must fail if that volume is missing; the wrapper must not create a replacement.

Use the fixed environment, /dev/null env file, both Compose files in this order, and postgres-only command:

    docker compose --project-name eventsales-prod --env-file /dev/null \
      -f /root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane/compose.yaml \
      -f <root-only recovery override> \
      up -d --no-deps postgres

Retain pre-removal, post-removal, immediately-pre-Compose, and post-Compose fingerprint checks. If the volume disappears before Compose, do not invoke Compose. The external declaration also ensures Docker Compose refuses a missing volume rather than creating an empty replacement.

## Production inventory and exact failed-container guard

Read the Compose-project inventory and eventsales-prod name-filter inventory. Each must contain exactly eventsales-prod-postgres-1. Reject every unexpected eventsales-prod container, including PgBouncer, Redis, or EventSales.

Require the exact known failed PostgreSQL object:

    name=eventsales-prod-postgres-1
    status=exited
    running=false
    restarting=false
    exit_code=1
    restart_count=24
    oom_killed=false
    image=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
    command=["postgres","-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]
    memory=3221225472
    nano_cpus=2000000000

Require no published ports, exactly the expected named volume mount, only the expected Compose bootstrap-secret mount, and the data network only. Validate the secret mount source internally but never print it.

Capture the full failed container ID and validate its Docker ID format as exactly 64 lowercase hexadecimal characters. Immediately before mutation, re-inspect that captured ID and prove the exact name, failed state, image, historical command, resources, volume, secret mount, network, and absence of ports. Then remove exactly that object using docker rm "$FAILED_POSTGRES_CONTAINER_ID", with no flags. Never remove by mutable name. If the ID changed or any field drifted, stop before removal.

## D0 isolation

Use the fixed com.docker.compose.project=eventsales-d0-proof label to list D0 IDs. Require exactly three unique valid IDs. Inspect each and require status=exited, running=false, restarting=false. Save and revalidate those same IDs and states after PostgreSQL recreation.

Never address a D0 container by name or mutate a D0 object. Do not use a D0 Compose file or project name. No recovery command may start, stop, attach, or otherwise affect D0.

## Docker operation allowlist

Allowed read-only Docker operations are limited to fixed production/D0 container listing, inspect of the fixed PostgreSQL object and captured D0 IDs, inspect of the two fixed networks, and list/inspect of the fixed PostgreSQL volume.

The only authorized Docker mutations are:

1. One docker rm "$FAILED_POSTGRES_CONTAINER_ID", where the full validated and immediately re-inspected ID is the known failed object. No flags.
2. One Compose up -d --no-deps postgres with the immutable c9ce Compose file first, the exact root-only external-volume override second, fixed project name, fixed environment, and /dev/null env file.
3. At most one docker stop --time 10 "$NEW_POSTGRES_CONTAINER_ID" if and only if the captured newly recreated PostgreSQL object is running or restarting after a post-Compose validation or health failure.

After Compose returns, capture the newly created PostgreSQL ID immediately and validate it as 64 lowercase hexadecimal characters. Require it to differ from FAILED_POSTGRES_CONTAINER_ID. Re-inspect and validate by this ID. All containment acts on this ID only, never the name. Never remove the new object. Never stop any other object.

For a Compose command failure, still inspect the fixed production inventory once to identify whether a new postgres object was created. If exactly one new object exists, capture its ID and apply the same stopped-or-running containment rule. If there is no new object, the PostgreSQL service is absent and the failure is contained. If a possible new object cannot be uniquely identified, do not guess or stop by name; classify the result as RECOVERY_FAILED_UNCONTAINED, emit a deterministic STOP, and require owner intervention because safe containment cannot be proven.

Forbid every other start, stop, restart, exec, rm, network, volume, prune, or Compose operation. Do not use Compose down, create, run, or up for any other service.

## Recreated-container validation and health

Immediately validate the new object by captured ID before health polling. Require:

    image=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
    Config.Cmd=["-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]
    Config.Cmd[0] != "postgres"
    memory=3221225472
    nano_cpus=2000000000
    restart_count=0
    running=true
    restarting=false
    oom_killed=false

Also require the same volume mounted at /var/lib/postgresql, only the existing data network, expected bootstrap-secret mount, and no published ports. Require production inventory to contain exactly this PostgreSQL object, and D0 IDs/states and network/volume identities to match the preflight snapshot.

Any mismatch is a post-Compose failure. If the exact new ID is running or restarting, transition to CONTAINING_FAILED_RECREATION and make one docker stop --time 10 call. Then inspect that ID and require running=false and restarting=false. A successful stop followed by verified stopped state ends RECOVERY_FAILED_CONTAINED; otherwise end RECOVERY_FAILED_UNCONTAINED. Do not retry containment.

Health checks have a fixed 120-second deadline and bounded polling interval. Require status=running, health=healthy, restart_count=0, and all runtime, attachment, volume, network, port, inventory, and D0 invariants on each poll. If any check fails while the object is running or restarting, perform the one containment stop, then verify stopped state. If it is already stopped, do not issue a stop. Health timeout follows the same rule. Missing object is a contained failure. No automatic recreation follows any failure.

Success requires healthy PostgreSQL, exactly one production container, no PgBouncer/Redis/app, unchanged volume and network identity, and the same three stopped D0 IDs. Emit only:

    POSTGRES_RECOVERY=HEALTHY
    POSTGRES_STATUS=running
    POSTGRES_HEALTH=healthy
    POSTGRES_RESTART_COUNT=0
    POSTGRES_IMAGE_MATCH=YES
    POSTGRES_COMMAND_CLASS=CORRECTED_FLAGS_ONLY
    POSTGRES_VOLUME_ATTACHMENT_MATCH=YES
    POSTGRES_NETWORK_ATTACHMENT_MATCH=YES
    POSTGRES_PORTS_PUBLISHED=NO
    POSTGRES_VOLUME_PRESERVED=YES
    PGBOUNCER_STARTED=NO
    REDIS_STARTED=NO
    APP_STARTED=NO
    D0_STATE=ARCHIVED_STOPPED

No raw Docker JSON, arbitrary metadata, secret values/hashes, secret mount source paths, or volume mountpoint may be printed.

## Sudo boundary

A future dedicated sudoers fragment contains only:

    agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-recover-postgres ""

Do not grant Docker, shell, wildcard, path-argument, or broad sudo authority. Leave all existing V2/V3/audit sudoers unchanged. The wrapper independently enforces root execution and zero arguments.

## Test strategy

Use isolated fixtures and fake Docker, following the existing V3 suite's test-only EUID pattern. Fake Docker records every call and rejects everything outside the allowlist. Tests never contact production Docker or a VPS.

Pre-mutation rejection coverage includes arguments; non-root; stage path/symlink/owner/write-bit drift; Compose symlink/type/owner/write/hash drift; secret directory and each required secret mismatch; data/edge network mismatch; missing, wrong, or fingerprint-changed volume; unexpected production inventory; missing/running/restarting PostgreSQL; all failed-state, image, command, resource, mount, network, port, and D0 mismatches.

Authority mechanics must explicitly cover unsafe /run metadata; lock path symlink; lock wrong ownership or mode; busy lock; consumed marker conflict as directory, file, or symlink; and marker-creation failure. Each proves no docker rm, no Compose, no docker stop, no volume mutation, and no D0 mutation.

Recovery-volume tests prove exact override content and hash, root-only metadata, no symlink, override passed as second Compose file, missing volume immediately before Compose results in no Compose invocation and no replacement volume, fingerprint change blocks Compose, and post-Compose fingerprint change fails closed.

Failed-object tests prove the exact captured validated ID is removed once and a changed/rebound name cannot redirect removal. Failed removal prevents Compose. Compose failure is not retried.

Post-recreation tests cover missing/ambiguous object, wrong image, wrong command and leading postgres, wrong resources, published port, wrong network, wrong volume, nonzero restart count, unhealthy state, health timeout, extra production container, changed D0 IDs/state, and changed volume/network identity. Model the listed contract and health failures with the new PostgreSQL object running or restarting and assert exactly one containment stop, targeting the new ID only. For an object already stopped, assert zero stop calls and verified stopped state. Every case asserts no second Compose, no new-object rm, no volume deletion, no D0 mutation, and persistent marker retained. Assert stop success plus verified stopped state leads to RECOVERY_FAILED_CONTAINED. Assert stop failure, unresolved object identity, or remaining running/restarting state leads to RECOVERY_FAILED_UNCONTAINED. No retries in either branch.

Success proves exactly one removal by the captured failed ID; exactly one Compose up with the override second; zero bootstrap/migration/secret regeneration; zero network/volume mutation; zero starts of PgBouncer, Redis, or app; zero D0 mutations; unchanged volume fingerprint; unchanged network and D0 identities; and exact safe output.

## Failure semantics and authority consumption

All read-only preflight checks, lock checks, and marker-path checks occur before authority consumption. Their failure produces no Docker mutation and leaves the marker absent. Atomic marker creation is the persistent point of no return. A marker-creation failure stops before Docker; a successfully created marker remains after any later success or failure.

After failed-container removal, there is no rollback authority. Recovery may make one Compose call and, if a newly created PostgreSQL object is running/restarting after failure, one containment stop by new ID. It may never retry removal, Compose, or stop. It may never delete storage or clear the marker.

## Installation and execution lifecycle

Implementation and tests require separate review. Installation then requires separate authorization: transfer only reviewed candidates, independently verify hashes, run VPS-native /usr/sbin/visudo -cf on the candidate fragment before activation, install wrapper root:root mode 0755 and sudoers root:root mode 0440, and verify file identities, metadata, and exact sudo listing. Do not edit historical sudoers or create/clear the marker during installation.

Execution requires separate explicit authorization and an exclusive Docker maintenance interval. Invoke exactly once using the zero-argument sudo rule, capture safe output and exit status, then stop. Do not run bootstrap, another wrapper, direct Docker commands, or a second recovery attempt.

## Historical authority evidence at design time

Historical files matched the accepted hashes:

    provision=4ede4ad5ae0696ee605bd890e3ced9a18d8d5ac4c7a11992325823de7e5cdad3
    start=b054b6e97da5e8455615534273168fe4322ce7f6800a5b6486892027df33b567
    bootstrap=b763431776faf81a8cc84b61c494b3ed22bb8bf732962306973878e83fae79ab
    v3 sudoers=8575c6c1e85d111bb78b360b8e03f2c9f6e6a1dfccc5fbc0273003a354bc51d3
    audit sudoers=52c7e97b51338bcaa34ebe74ed5731055bf3dfa36000af3fa826315ce5a2d974

The historical start wrapper still pins the prior stage and remains byte-identical. Recovery is a separate authority and must not modify it.
