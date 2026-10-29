# EventSales V3 PostgreSQL recovery design

## Status

Design for review only. This document does not authorize installation or recovery. No wrapper has been implemented.

## Goal and non-goals

Add a dedicated, zero-argument, one-shot root wrapper to replace only the known failed PostgreSQL container with one created from the corrected immutable c9ce stage:

```text
SOURCE_SHA=c9ce0f9239123a6e58f66fde0b5a1e60238bb107
STAGE=/root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane
COMPOSE_SHA256=3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218
```

The corrected Compose source in the repository has the expected hash. Its PostgreSQL command is flags-only, image digest is pinned, resources are 3 GiB and 2 CPUs, it names the existing volume, uses the internal data network, publishes no ports, and has a health check.

The wrapper does not bootstrap, migrate, rotate or rerender secrets; start PgBouncer, Redis, EventSales, or D0; change networks or volumes; edit any historical V3 authority; repair a failed attempt; or print Docker JSON, secret values, secret hashes, or secret mount source paths.

## State machine and terminal states

```text
FAILED_CONTAINED
  | all preconditions pass
  v
RECOVERY_AUTHORIZED
  | one-shot marker created
  v
REMOVING_FAILED_CONTAINER
  | exact stopped container removed
  v
RECREATING
  | postgres only, from corrected immutable Compose
  v
HEALTH_CHECKING
  | runtime contract and health pass
  v
RECOVERED_HEALTHY
```

Any failure in removal, recreation, or health checking ends in `RECOVERY_FAILED_CONTAINED`. The wrapper stops without retry, rollback, stopping a newly created container, or deleting storage. Depending on the failure point, PostgreSQL may be absent, exited, starting, unhealthy, or restarting. Only PostgreSQL may have been started; it has no published ports and is configured only on the internal data network. PgBouncer, Redis, EventSales, and D0 remain stopped. A new recovery attempt needs a separately reviewed authority.

## Entry, environment, and concurrency guards

Start the executable with:

```bash
#!/bin/bash -p
set -euo pipefail
set +x
umask 077
```

Reject arguments and require `EUID=0`. Set fixed `PATH=/usr/sbin:/usr/bin:/sbin:/bin`, `LC_ALL=C`, and `DOCKER_HOST=unix:///var/run/docker.sock`. Unset caller-controlled `BASH_ENV`, `ENV`, `CDPATH`, every `DOCKER_*` and `COMPOSE_*` variable, and `EVENTSALES_SECRET_DIR`. Set only fixed values, change to `/`, and run each Docker command with a cleared environment and the fixed socket.

Take a nonblocking `flock` on `/run/agent-eventsales-v3-recover-postgres.lock`; hold it through final verification. Require `/run` and the lock file to be non-symlink root-owned paths with safe permissions. A busy or unsafe lock stops before Docker access. This serializes invocations of this wrapper.

Also require an exclusive Docker maintenance interval. Existing V3 wrappers do not use this lock. No root operator or other `agentops` session may run direct Docker commands or invoke historical start, bootstrap, or provision wrappers until the recovery ends. If exclusive Docker access cannot be established, stop with `UNRESOLVED_CONCURRENCY`.

Once all read-only preconditions pass, atomically create `/root/eventsales-prod/.v3-postgres-recovery-consumed` as a `root:root` directory with mode `0700`, immediately before the first Docker mutation. Never overwrite or follow an existing path and never remove the marker. A preflight failure does not consume authority. Marker creation consumes it even if `docker rm` then fails. A later invocation sees the marker and stops before Docker.

The marker is authority bookkeeping, not a Docker mutation. The only Docker mutations are the two operations in the allowlist below.

## Stage trust checks

Before any Docker mutation, require each path below to be a non-symlink directory owned by uid 0 and gid 0 with no group/other write bits:

```text
/root
/root/eventsales-prod
/root/eventsales-prod/staged
/root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107
/root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane
```

Require `compose.yaml` to be a non-symlink regular file owned by root:root, with no write bits, and SHA-256 `3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218`. Recheck the hash immediately before Compose. The directory name alone does not prove file identity.

## Secret handling

Require `/root/eventsales-prod/secrets-v1` to be a non-symlink `root:root` directory, mode `0700`. Match the current V3 start/bootstrap metadata contract. Every listed item must be a non-symlink regular file:

| File | uid:gid | Mode | Size |
| --- | --- | --- | --- |
| `postgres_bootstrap_password` | `0:70` | `0440` | 64 |
| `eventsales_migrator_password` | `0:0` | `0400` | 64 |
| `eventsales_runtime_server_password` | `0:0` | `0400` | 64 |
| `eventsales_runtime_client_password` | `0:0` | `0400` | 64 |
| `eventsales_backup_password` | `0:0` | `0400` | 64 |
| `redis_runtime_password` | `0:0` | `0400` | 64 |
| `redis_stats_password` | `0:0` | `0400` | 64 |
| `pgbouncer.ini` | `0:65532` | `0440` | nonempty |
| `pgbouncer_users.txt` | `0:65532` | `0440` | nonempty |
| `redis-users.acl` | `0:65532` | `0440` | nonempty |

Check metadata only. Never read or print secret contents or hashes. Compose declares all four file-backed secrets, so require the three non-PostgreSQL rendered files too. The initialized database volume remains authoritative. Mounting the bootstrap secret does not reset an existing database password. Do not invoke bootstrap.

## Network guards

Before removal, require both existing networks and exact metadata:

```text
eventsales-prod_eventsales_data: driver=bridge, internal=true
eventsales-prod_eventsales_edge: driver=bridge, internal=false
```

Record their Docker IDs. Recheck IDs and metadata after container removal and after recreation. The data network is external in Compose. The wrapper has no network mutation command.

## Volume preservation invariant

Never call `docker volume rm`, `docker compose down -v`, `docker system prune`, or an equivalent command. Never pass `-v` or `--volumes` to `docker rm`.

Require `eventsales-prod_postgres_data` to exist, with exact name, local driver, local scope, and a non-symlink mountpoint directory. Capture its mountpoint device/inode fingerprint in memory. Require the failed container to have exactly one volume mount with that name at `/var/lib/postgresql`.

Immediately after removal, re-inspect the same volume and require its metadata and fingerprint to match before Compose. After Compose, require the new container to use the same volume and fingerprint. Do not print the mountpoint. If any check fails, stop without retry.

The corrected Compose names the volume but does not set `external: true`; Compose can create it if it is missing. The existence checks, unchanged fingerprint, and exclusive Docker maintenance interval are therefore mandatory. If the volume's local identity cannot be established, stop with `UNRESOLVED_VOLUME_IDENTITY` before container removal.

## Production and failed-container guards

Read both the Compose-project inventory and the `eventsales-prod` name-filter inventory. Require each to contain exactly `eventsales-prod-postgres-1`. Reject any other production container, including PgBouncer, Redis, or EventSales.

Require the exact failed PostgreSQL object:

```text
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
```

Require no published ports. Require exactly the expected named volume mount and only the expected Compose bootstrap-secret mount. Validate the secret mount's fixed source internally without printing it. Require the data network only.

Read the PostgreSQL container ID and recheck all failed-object fields immediately before `docker rm eventsales-prod-postgres-1`. The lock and exclusive maintenance interval prevent cooperating actors from replacing it between the check and removal.

## D0 isolation

Use `com.docker.compose.project=eventsales-d0-proof` to list D0 container IDs. Require exactly three IDs. Inspect each and require `status=exited`, `running=false`, `restarting=false`. Save all three IDs.

Never mutate or address D0 containers by name. After PostgreSQL recreation, list by the same project label and require the same three IDs and stopped states. Do not use a D0 Compose file or project name.

## Docker operation allowlist

Read-only commands:

- `docker ps -a` with fixed production and D0 filters.
- `docker inspect` for the fixed PostgreSQL container and D0 IDs.
- `docker network inspect` for the two fixed production networks.
- `docker volume ls` and `docker volume inspect` for the fixed PostgreSQL volume.

Exactly two Docker mutations:

1. `docker rm eventsales-prod-postgres-1`, without force or volume flags.
2. `docker compose --project-name eventsales-prod --env-file /dev/null -f /root/eventsales-prod/staged/c9ce0f9239123a6e58f66fde0b5a1e60238bb107/data-plane/compose.yaml up -d --no-deps postgres`, with only the fixed `EVENTSALES_SECRET_DIR` and cleared environment.

The second command starts PostgreSQL only. It does not start dependencies or run bootstrap. Suppress raw Docker output. On failure, emit one fixed STOP reason. On success, emit only the safe output below.

Forbid Docker start/stop/restart/exec, `docker rm` of any other object or with force/volume flags, all network/volume mutation commands, Compose `down`, `create`, `run`, or `up` for any other service, and all prune commands.

## Corrected runtime and health contract

Immediately after Compose returns and on every health poll, require:

```text
image=dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19
Config.Cmd=["-c","max_connections=100","-c","shared_buffers=768MB","-c","effective_cache_size=2GB","-c","work_mem=8MB","-c","maintenance_work_mem=256MB"]
Config.Cmd[0] != "postgres"
memory=3221225472
nano_cpus=2000000000
restart_count=0
running=true
oom_killed=false
```

Also require the same volume at `/var/lib/postgresql`, the same data network only, the expected secret mount, and no published ports. A nonzero restart count, exited/dead state, unhealthy state, inspect failure, or contract mismatch stops immediately. Never recreate again.

Poll with a fixed interval and a fixed 120-second deadline. Missing container or failed inspect is an error, not grounds to retry. Success requires `status=running` and `health=healthy`.

After health passes, require exactly one production container, no PgBouncer/Redis/app containers, unchanged volume/network identity, and the same three stopped D0 IDs. Emit exactly:

```text
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
```

Do not include arbitrary metadata, Docker JSON, secret content/hash, or mount host paths. On any post-marker failure, retain the marker and stop without retry or rollback.

## Sudo boundary

Add a new fragment containing only:

```text
agentops ALL=(root) NOPASSWD: /usr/local/sbin/agent-eventsales-v3-recover-postgres ""
```

No Docker command, shell, wildcard, path argument, or `ALL` authority. Leave existing V2/V3/audit sudoers byte-identical. The wrapper also enforces zero arguments and EUID 0.

## Test strategy

Use a shell suite with temporary fixtures and fake Docker, following the existing V3 tests' test-only EUID pattern. Log and reject every Docker call outside the allowlist. Every pre-mutation rejection proves remove and Compose were not called. Every test proves no volume deletion or D0 mutation.

Cover all requested pre-mutation cases: arguments, non-root, stage symlinks/ownership/write bits, Compose symlink/type/ownership/write/hash, secret directory and bootstrap secret metadata, other rendered secrets, both network mismatches, missing or changed volume, unexpected production containers, missing/running/restarting PostgreSQL, wrong status/exit/restart/OOM/image/command/resources, wrong/extra volume or destination, wrong network, published ports, and D0 count/running/restarting drift.

Cover mutation failures: failed `docker rm` stops before Compose; failed Compose is not retried; recreated container missing; wrong image/command including leading `postgres`; nonzero restarts; exited/dead/unhealthy state; timeout; resource, volume, network, mount, or port mismatch; extra production container; changed D0 IDs or state. Each proves one-shot consumption, no retry, no rollback, and no volume deletion.

Success must prove one exact `docker rm`, one Compose `up -d --no-deps postgres`, zero bootstrap, zero network/volume mutation, zero PgBouncer/Redis/app starts, unchanged D0 IDs, preserved volume fingerprint, and exact safe output.

## Installation and execution lifecycle

Implementation and tests require review first. A later installation task must transfer only reviewed candidates, independently hash them, run VPS-native `/usr/sbin/visudo -cf` on the candidate before activation, install the wrapper root:root mode `0755` and sudoers root:root mode `0440`, then verify hashes, metadata, and exact sudo listing. Do not edit historical sudoers or create/clear the consumed marker during installation.

Execution needs separate explicit authorization and an exclusive Docker maintenance interval. Invoke exactly once with `sudo -n /usr/local/sbin/agent-eventsales-v3-recover-postgres`. Capture safe output and exit status. Stop after PASS or STOP. Do not run bootstrap, another wrapper, or Docker afterward.

Preflight failures occur before authority consumption. After every precondition passes, atomically create the persistent consumed marker before removal. This consumes authority even when removal fails. A second invocation stops before Docker. Reset requires separately reviewed authority.

## Repository evidence

At design time `HEAD` and `origin/main` were:

```text
MAIN_SHA=86c023afb9b5f18c8c8230e1e739453c4c722c30
MAIN_TREE=705facd5f932a1dd7fa107514b9cc14a0c377d0b
```

The corrected repository Compose hash was `3f41703fd15decd8c6a174142f8eaa4e205383cad539ddaf0ae4cd7a944fb218`. Historical authority hashes matched:

```text
provision=4ede4ad5ae0696ee605bd890e3ced9a18d8d5ac4c7a11992325823de7e5cdad3
start=b054b6e97da5e8455615534273168fe4322ce7f6800a5b6486892027df33b567
bootstrap=b763431776faf81a8cc84b61c494b3ed22bb8bf732962306973878e83fae79ab
v3 sudoers=8575c6c1e85d111bb78b360b8e03f2c9f6e6a1dfccc5fbc0273003a354bc51d3
audit sudoers=52c7e97b51338bcaa34ebe74ed5731055bf3dfa36000af3fa826315ce5a2d974
```

The historical start wrapper still pins the old stage and Compose hash. It remains byte-identical. The recovery wrapper is a separate authority.
