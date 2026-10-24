# EventSales production data plane

This directory defines the future `eventsales-prod` Compose project. It contains PostgreSQL, PgBouncer, and Redis only. These files are versioned deployment inputs; they do not start services, create secrets, or authorize VPS changes.

The accepted R3.4 PgBouncer image is pinned directly in `compose.yaml`:

```text
ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:965b0223f1096666471e11595f4f6dc5d32dfacbc688418b8ae2385946c41e3b
```

Do not replace it with a tag, rebuild it, or substitute the raw DHI build base. The immutable image provenance records its base and builder inputs.

## Boundary

The intended production boundary is:

```text
3 containers / 2 networks / 1 volume
```

The only volume is `eventsales-prod_postgres_data`. A data-plane lifecycle script provisions and validates both shared networks before either Compose project starts:

| Network | Driver | Internal | Members |
|---|---|---:|---|
| `eventsales-prod_eventsales_data` | bridge | yes | PostgreSQL, PgBouncer, Redis; later EventSales app |
| `eventsales-prod_eventsales_edge` | bridge | no | later EventSales app only |

The data-plane Compose project consumes only the external `eventsales_data` network. No data service joins `eventsales_edge`. The separate `eventsales-app` project later consumes both networks as external. Routine `docker compose down` does not remove either network. The provisioner creates an absent network, validates an existing network without changing it, and stops if the driver or internal flag differs. It never repairs conflicts or deletes networks. No service publishes a host port. The existing `eventsales-d0-proof` project, its networks, volume, data, and credentials remain separate and untouched.

Network creation is sequential and has no rollback. If data-network creation succeeds and edge-network creation fails, the script exits non-zero and leaves the valid data network in place. On the next invocation, it validates that network without changing it and creates only the missing edge network. It never deletes or recreates the surviving network.

The app project may later attach to both production networks by their exact names. That later application configuration does not make the app a member of this Compose project.

## Future operational order

The later VPS procedure must follow this order:

1. Preflight and provision or validate both shared networks.
2. Prepare the secret and runtime configuration files under the separate R4.2 authority.
3. Start and manage the `eventsales-prod` data-plane Compose project.
4. Start and manage the separate `eventsales-app` project, which consumes both networks externally.

These repository files define the future procedure only. They do not authorize running the network provisioner, creating production resources, or starting either Compose project on the VPS.

## PostgreSQL database and volume lifecycle

R4.1 initializes only the PostgreSQL `postgres` maintenance database. R4.3 owns the one-shot creation of `event_sales_prod` and must set its owner to `eventsales_migrator` before migrations.

The Compose-owned `eventsales-prod_postgres_data` volume follows this lifecycle:

| State | Allowed action |
|---|---|
| `INITIAL_ABSENT` | Compose may create the named volume when the approved data-plane project first starts. |
| `EXPECTED_PRESENT` | A later approved data-plane lifecycle may reuse the accepted production volume. |
| `UNEXPECTED_PREEXISTING_BEFORE_FIRST_PROVISION` | Stop for review. Do not attach, replace, or delete it automatically. |
| `DELETION` | Requires separate destructive authority. R4.1 does not authorize it. |

Do not run `docker compose down -v`, `docker compose down --volumes`, `docker volume rm eventsales-prod_postgres_data`, or `docker volume prune` against production. No R4.1 command deletes or recreates the production database volume.

## Image and health contracts

```text
PostgreSQL
  dhi.io/postgres:18.6-alpine3.24@sha256:d33bd884995daddfb515d0ce9aec23b74d20d72e03ca42b72c4abf617c76bb19

PgBouncer
  ghcr.io/jcschoeman96/eventsales-pgbouncer@sha256:965b0223f1096666471e11595f4f6dc5d32dfacbc688418b8ae2385946c41e3b

Redis
  dhi.io/redis:8.10.2-debian13@sha256:953ca2c2ab4ff7a93f8abac31339ba4d913ec0914861453ab4faa29d154115a0
```

The Compose healthchecks use only binaries present in those exact images. PgBouncer runs the R3.4 static probe as `127.0.0.1 6432 eventsales_runtime`; an exit status of zero means the listener parsed PostgreSQL startup and advertised the SCRAM-SHA-256 auth path. It does not prove a real user, password, backend, pool, or SQL operation. The later PgBouncer proof owns those checks.

The Redis default ACL identity can run only `PING`, which supports the container healthcheck. It has no key access. Runtime commands require the named `eventsales_runtime` identity and its generated password. `eventsales_stats` is a separately authenticated read-only identity.

Redis runs with `protected-mode=no` so named authenticated clients can connect over the internal Docker bridge. The production access boundary is the internal data network plus Redis ACLs. Redis has no host port. The passwordless default identity remains limited to `PING` and has no key patterns.

PostgreSQL runs with the approved container-local settings: `max_connections=100`, `shared_buffers=768MB`, `effective_cache_size=2GB`, `work_mem=8MB`, and `maintenance_work_mem=256MB`.

## Runtime files and permissions

Set `EVENTSALES_SECRET_DIR` to an absolute protected directory containing the generated files below before invoking Compose:

```text
postgres_bootstrap_password
pgbouncer.ini
pgbouncer_users.txt
redis-users.acl
```

The Compose model mounts each file read-only only into the service that needs it. No secret values belong in Compose, templates, `.env` files, command arguments, or repository artifacts. `pgbouncer.ini`, `pgbouncer_users.txt`, and `redis-users.acl` are secret-bearing after rendering; the checked-in templates contain placeholders only.

File-backed Compose secrets use read-only host file mounts; Compose does not remap their ownership or mode. Before any later deployment, the generated directory and files must therefore be traversable/readable by the service UID while remaining inaccessible to unrelated users. The intended file owners are root with group `70` for `postgres_bootstrap_password` and root with group `65532` for the PgBouncer and Redis files; each file must be mode `0440`, with a root-owned, non-writable secret directory. The image UIDs are PostgreSQL `70`, PgBouncer `65532`, and Redis `65532`. R4.2 owns creation and permission verification; this README does not authorize creating those files.

The PostgreSQL bootstrap password is supplied through `POSTGRES_PASSWORD_FILE`. It is used only for initial database bootstrap and must not become an application runtime credential. PgBouncer's generated config holds the PostgreSQL server password; the auth file holds client authentication verifiers. Redis ACL password placeholders are SHA-256 digests of separately generated passwords.

## R4.4 one-shot data-plane proofs

These host-side probes may run only after the accepted V3/V4 procedure has created and started the production data plane and a future V5 authority explicitly authorizes the proof. Repository merge does not authorize VPS execution. Both probes require root and the absolute R4.2 secret directory; each validates only its required raw password files and writes mode-0600 evidence there. The probes inspect and execute bounded clients against the already-running `eventsales-prod` services. They do not create, start, restart, or stop services.

`agentops` remains unprivileged. Production root execution must use a separately reviewed narrow sudo/root wrapper that executes reviewed, root-owned immutable staged bytes. Never execute these privileged scripts directly from an `agentops`-writable Git checkout. The exact wrapper and installation invocation will be defined and reviewed before V5. R4.4 does not implement that wrapper.

Each probe is one-shot. A failed run preserves its evidence and must stop for review; failed PostgreSQL proof objects remain in place. Do not blindly rerun a failed or successful proof, repair its state automatically, or perform automatic destructive cleanup. Do not use `--rm` helper containers for failure-sensitive proof. Successful evidence and proof artifacts remain until explicit acceptance and cleanup authority is granted. The PostgreSQL proof table is retained for later V5 acceptance; Redis proof keys expire under their 60-second rate-limit and one-hour hot-state TTLs.

## Configuration-only validation

Compose rendering can be checked with disposable empty fixture files; it does not require image pulls or service startup:

```bash
EVENTSALES_SECRET_DIR=/tmp/eventsales-compose-fixtures \
  docker compose --project-name eventsales-prod \
    --env-file /dev/null \
    -f deploy/vps/data-plane/compose.yaml \
    config
```

Use only non-secret fixture paths and values for configuration checks. Do not run `up`, create production secrets, stage files on the VPS, or touch the D0 project as part of this repository checkpoint. Those actions require separate authority.
