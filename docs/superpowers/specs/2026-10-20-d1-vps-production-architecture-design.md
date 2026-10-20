# EventSales D1 VPS Production Architecture Design

**Date:** 2026-10-20  
**Repository:** `JCSchoeman96/EventSales`  
**Authority base:** `main` at `13ca53d5e1671b2fde4ab21e7e2725a5a27bb2d2`  
**Status:** Design approved in chat; written spec awaiting final user review  
**Implementation authority:** **NO**

---

## 1. Purpose

D0 proved a disposable VPS data plane using PostgreSQL, PgBouncer transaction pooling, and a dedicated Redis instance without disturbing the existing CyberPanel/OpenLiteSpeed/MariaDB/host-Redis stack. D1 productionizes that architecture without mutating the accepted D0 proof.

The goal is to deploy EventSales as a production Phoenix application on the VPS with:

- an isolated production PostgreSQL database;
- PgBouncer in transaction-pooling mode;
- a dedicated production Redis namespace and least-privilege ACL;
- an immutable application image deployed by digest;
- explicit one-shot migration authority;
- a private application proof before any host port is published;
- loopback-only ingress on `127.0.0.1:4100` before OpenLiteSpeed routing;
- a separate public cutover gate with rollback.

D1 does **not** authorize VPS mutation, application deployment, database migration, secret generation, or OpenLiteSpeed changes by itself.

---

## 2. Ultimate Goal and Backward Plan

The long-term target is a horizontally scalable EventSales runtime where hot state is served from ETS/GenServers, warm state from Redis, durable truth from PostgreSQL, asynchronous work from Oban, real-time UI through Phoenix PubSub/LiveView, and public ingress through OpenLiteSpeed/CDN layers.

Working backward from that target:

1. Public traffic must terminate at OpenLiteSpeed and proxy only to a verified loopback Phoenix endpoint.
2. The loopback endpoint must expose an application already proven healthy and ready while private.
3. The private application must use an immutable reviewed image and proven production credentials.
4. Runtime database traffic must use transaction-pooled PgBouncer; migrations must use the direct PostgreSQL path.
5. Oban notifications must not depend on PostgreSQL `LISTEN/NOTIFY` because transaction pooling cannot preserve session-level listeners.
6. Production Redis ACLs must match the exact command families EventSales actually uses, not the reduced D0 proof command set.
7. Production data services must be separate from the accepted D0 proof so rollback never requires reconstructing proof evidence.
8. D0 therefore remains frozen and the production stack is created in parallel.

The MVP of this final system is one production application node, one production PostgreSQL primary, one PgBouncer, one Redis, one private application proof, then loopback ingress and finally public routing. Read replicas and multi-node application scaling remain mandatory later scaling gates before claiming 100k-concurrent-user readiness.

---

## 3. Frozen D0 Baseline

The following D0 state is accepted evidence and is not a production environment:

```text
eventsales-d0-proof
├── postgres
├── pgbouncer
├── redis
├── eventsales_data
└── eventsales_edge
```

Canonical D0 properties:

- final Docker boundary: `3 containers / 2 networks / 1 volume`;
- PostgreSQL, PgBouncer, and Redis healthy with zero restarts at closeout;
- database: `eventsales_proof`;
- PgBouncer mode: `transaction`;
- runtime DB DML proven through PgBouncer;
- runtime DDL denied;
- direct runtime PostgreSQL authentication denied;
- PgBouncer transaction pooling proven;
- dedicated EventSales Redis proven;
- host Redis unchanged;
- no probe containers remain;
- D0 secrets and R16 artifacts remain evidence, not production credentials.

### D0 invariant

No D1 task may mutate, rename, reuse, rotate, delete, restart, or repurpose the accepted D0 stack unless a later authority explicitly reopens D0 because of a proven contradiction.

---

## 4. Selected Production Topology

The selected approach is a **parallel production data plane**.

```text
Accepted proof — frozen                 Production — new

 eventsales-d0-proof                     eventsales-prod
 ├── PostgreSQL                          ├── PostgreSQL
 │   └── eventsales_proof                │   └── event_sales_prod
 ├── PgBouncer                           ├── PgBouncer
 ├── Redis                               ├── Redis
 ├── internal data network               ├── internal data network
 └── edge network                        └── edge network
                                                │
                                                ▼
                                        eventsales-app
                                        └── EventSales Phoenix
```

The production data project name is `eventsales-prod`.

The application is deployed as a separate Compose project, `eventsales-app`, and joins the production networks as external networks. This prevents routine application deploys from treating PostgreSQL, PgBouncer, or Redis as application dependencies that Compose may recreate.

### Production network names

```text
eventsales-prod_eventsales_data
eventsales-prod_eventsales_edge
```

### Network membership

- PostgreSQL: `eventsales_data` only.
- PgBouncer: `eventsales_data` only.
- Redis: `eventsales_data` only.
- EventSales app: `eventsales_data` + `eventsales_edge`.
- No data service publishes a host port.
- App publishes no host port during private proof.
- After private acceptance, app may publish `127.0.0.1:4100:4000` under a separate ingress authority.

---

## 5. Domain / Resource Map

### 5.1 ProductionDataPlane

Owns:

- production PostgreSQL container and volume;
- production PgBouncer container and config;
- production Redis container and ACL;
- production internal/edge networks;
- data-plane secrets.

Does not own:

- application image;
- application lifecycle;
- OpenLiteSpeed configuration.

### 5.2 AppArtifact

Owns:

- one EventSales Git commit;
- one CI-built production image;
- one immutable registry digest;
- build provenance/SBOM metadata.

Deployment consumes only an approved digest. Production never builds from repository source on the VPS.

### 5.3 MigrationRun

Owns:

- one reviewed app image digest;
- one migration authorization;
- `DIRECT_DATABASE_URL` using the migrator role;
- migration output and post-migration evidence.

It is separate from normal application startup.

### 5.4 RuntimeApp

Owns:

- Phoenix/Bandit runtime;
- EventSales.Repo runtime connection through PgBouncer;
- Oban;
- Redix connections;
- DNSCluster/Phoenix PubSub;
- health/readiness;
- eventual loopback ingress.

The long-running app never receives PostgreSQL bootstrap, backup, or migrator credentials.

### 5.5 BootstrapRun

Owns first-production admin/source-system bootstrap only. Bootstrap secrets are temporary deployment inputs and must not remain in the final long-running runtime environment after bootstrap succeeds.

### 5.6 LoopbackIngress

Owns only the `127.0.0.1:4100:4000` host publication and its verification. It does not own OpenLiteSpeed.

### 5.7 OLSRoute

Owns OpenLiteSpeed upstream configuration, proxy headers, WebSocket upgrade behavior, public hostname routing, and rollback.

---

## 6. PostgreSQL Production Contract

### 6.1 Database

```text
event_sales_prod
```

The production database is new. `eventsales_proof` is never upgraded into production.

### 6.2 Roles

Fresh production credentials are generated for:

```text
eventsales_migrator
eventsales_runtime
eventsales_backup
```

Initial role connection limits:

```text
eventsales_migrator = 2
eventsales_backup   = 2
eventsales_runtime  = 20
```

### 6.3 Ownership and privileges

`eventsales_migrator` owns `event_sales_prod` and application-created schema objects.

Production bootstrap must establish before migrations:

- runtime `CONNECT` on the production database;
- runtime `USAGE` on application schemas;
- runtime DML privileges on migrator-created tables;
- runtime sequence privileges required by Ecto/Ash;
- runtime `EXECUTE` on migrator-created application functions where required;
- backup `CONNECT`, schema `USAGE`, and table read privileges;
- default privileges for future migrator-created tables, sequences, and functions;
- no unintended `PUBLIC` create privilege.

The default-privilege contract is mandatory so future migrations do not require manual grant repair.

### 6.4 Extensions/functions

The repository declares `citext` and Ash helper functions through `EventSales.Repo.installed_extensions/0`. Production migration proof must demonstrate the migrator can install/create every required extension/function on an empty production database before application deployment is authorized.

### 6.5 Initial container envelope

Initial PostgreSQL container limits:

```text
CPU:    2
Memory: 3 GiB
```

Initial PostgreSQL tuning target:

```text
max_connections       = 100
shared_buffers        = 768MB
effective_cache_size  = 2GB
work_mem              = 8MB
maintenance_work_mem  = 256MB
```

These values are container-local and must not alter host PostgreSQL/MariaDB settings.

Indexes required by application migrations remain migration-owned. No peak path may depend on a large table scan; analytics/dashboard scaling later adds read replicas and cached/materialized aggregates before flash-sale-scale readiness is claimed.

---

## 7. PgBouncer Production Contract

PgBouncer remains in **transaction mode**.

Initial production configuration:

```ini
pool_mode = transaction
max_client_conn = 64
default_pool_size = 12
reserve_pool_size = 4
max_db_connections = 16
max_user_connections = 16
max_prepared_statements = 200
```

The production runtime role may have up to 20 client connections from the app, while PgBouncer bounds active PostgreSQL backends to 16.

### Prepared statements

Do not add `prepare: :unnamed` as a default workaround. The production proof must demonstrate real Postgrex/Ecto/Ash queries through PgBouncer with named prepared-statement support enabled via `max_prepared_statements = 200`.

If that proof fails, D1 stops. The remediation must be reviewed from evidence before changing Ecto preparation behavior.

### Security

PgBouncer:

- pinned image digest;
- non-root runtime;
- read-only root filesystem;
- no host port;
- internal data network only;
- `no-new-privileges`;
- all Linux capabilities dropped unless a demonstrated runtime need exists;
- bounded memory/CPU;
- SCRAM credentials;
- separate client and PostgreSQL server passwords for the runtime role.

---

## 8. Oban and Distributed Erlang

Current repository architecture uses `Oban.Notifiers.Postgres`, which depends on PostgreSQL notification session semantics. D1 changes the production notifier to `Oban.Notifiers.PG` so Oban does not depend on PostgreSQL `LISTEN/NOTIFY` through transaction-pooled PgBouncer.

### Selected model

```text
Oban SQL
  -> EventSales.Repo
  -> PgBouncer transaction pool
  -> PostgreSQL

Oban notifications
  -> Oban.Notifiers.PG
  -> Erlang process groups across connected EventSales nodes
```

The repository already supervises `DNSCluster`; D1 must use that existing clustering boundary rather than introduce a second cluster mechanism.

### First-node requirements

The first production EventSales node must run as a distributed Erlang node from day one, with:

- explicit release node identity;
- a production release cookie stored only in the protected deployment environment;
- DNSCluster query configured so future nodes can join without changing the notifier architecture;
- single-node behavior proven before horizontal scaling.

Multi-node topology is not part of the first deployment, but the first node must not create a notifier architecture that has to be replaced to scale.

### Oban peer/leadership

Database-backed Oban leadership remains database-backed unless implementation evidence proves a change is required. D1 changes the notifier path, not queue ownership semantics or job durability.

---

## 9. Redis Production Contract

Production Redis is a new service with fresh credentials and production-only keys.

### Namespace

```text
eventsales:prod:*
```

The D0 ACL `eventsales:proof:*` is not extended or reused.

### Initial runtime command family

The production runtime ACL must permit only commands required by enabled production code:

```text
PING
GET
SET
DEL
EXISTS
EXPIRE
PEXPIRE
TTL
PTTL
MULTI
EXEC
DISCARD
ZADD
ZREM
ZCARD
ZREMRANGEBYSCORE
SCAN
```

This supports the current shared webhook rate limiter and hot-state snapshot adapter. The ACL is accepted only after integration tests prove all required operations and prove unrelated commands remain denied.

### Stats identity

A separate statistics identity may read operational information but may not write application data. Its command set remains narrowly scoped to required inspection commands such as `PING`, `INFO`, and `CONFIG GET`.

### Webhook degraded buffer

Initial production configuration is explicitly:

```text
WEBHOOK_REDIS_BUFFER_ENABLED=false
WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED=false
```

The degraded webhook buffer is not enabled because it requires Lua/list commands and the current Redis architecture deliberately disables persistence. No claim of durable degraded buffering may be made until a separate durability design is accepted.

### Hot/warm state

Production hot-state snapshots use the existing Redis adapter with bounded restore behavior and TTL. Redis remains warm/cache state; PostgreSQL remains durable truth.

Initial Redis envelope:

```text
CPU:                  0.5
Container memory:     512 MiB
Redis maxmemory:      384 MiB
maxmemory-policy:     noeviction
Persistence:          disabled
```

Cache invalidation follows existing domain events and application ownership. D1 must not add polling where PubSub/GenServer updates already exist.

---

## 10. Application Runtime Contract

### 10.1 Immutable image

Production runs only an immutable image digest:

```text
ghcr.io/jcschoeman96/eventsales@sha256:<approved-digest>
```

No production `build:` directive is permitted.

### 10.2 Initial application envelope

```text
CPU:        4
Memory:     2 GiB
PIDs limit: 512
```

The app:

- runs as the non-root image user;
- uses a read-only root filesystem;
- receives writable `tmpfs` only where proven necessary;
- drops all Linux capabilities;
- uses `no-new-privileges`;
- logs to stdout/stderr;
- stores no durable state in its container filesystem;
- uses `init: true`;
- uses an explicit restart policy that returns after host reboot but does not hide crash evidence from health/monitoring.

Production disables runtime tzdata auto-update so timezone database changes arrive through a reviewed image rebuild rather than filesystem mutation.

### 10.3 Database runtime URL

Runtime database traffic uses:

```text
DATABASE_URL -> pgbouncer:6432/event_sales_prod -> eventsales_runtime
POOL_SIZE    = 20
```

The long-running app must not receive `DIRECT_DATABASE_URL`, the migrator password, PostgreSQL bootstrap credentials, or backup credentials.

### 10.4 Redis runtime URL

`REDIS_URL` uses the production Redis runtime identity and production namespace.

### 10.5 Health

The repository already has:

- `/health` for liveness;
- `/ready` backed by `EventSales.Health.DatabaseReadiness` for database readiness.

Container liveness may use release-process health (`bin/event_sales pid`) without adding an HTTP client package to the runtime image. Private deployment readiness is verified from the running node and/or an isolated probe. Once loopback ingress exists, `/health` and `/ready` must also be proven over HTTP.

No readiness endpoint may perform one database query per HTTP request; the existing ETS snapshot design is retained.

---

## 11. Secret and Environment Boundaries

Production credentials are freshly generated. No R16/D0 proof password is copied into production.

Host deployment material lives under a production root-owned directory such as:

```text
/root/eventsales-prod/
├── data-plane/
├── app/
├── env/
└── secrets/
```

Directories containing secrets are `root:root` mode `0700`; protected files are `0400` unless a service-specific UID/GID requires a stricter explicit ownership contract.

### Runtime environment

The final long-running app environment contains only runtime-required values, including runtime DB/Redis credentials, Phoenix secrets, public host/origin configuration, feature flags, and clustering values.

### Migration environment

The migration environment additionally contains `DIRECT_DATABASE_URL` using `eventsales_migrator`. It is used only by a one-shot migration container/process.

### Bootstrap environment

Bootstrap admin credentials exist only for the bootstrap lifecycle. The initial private app may temporarily receive bootstrap variables, bootstrap is explicitly invoked after readiness, then the app is recreated from the same image without bootstrap credentials. The final runtime container must not retain the bootstrap admin password.

### Exposure rule

Secret values must never be printed, logged, committed, hashed for reporting, or passed as command-line arguments. Docker/environment visibility is restricted to root/Docker-authorized operators; the existing unprivileged `agentops` boundary must remain intact.

---

## 12. Migration and Bootstrap Flow

### Migration

Normal app startup remains:

```text
bin/event_sales start
```

It must never silently run migrations.

One-shot production migration uses the reviewed image and:

```elixir
EventSales.Release.migrate()
```

with `DIRECT_DATABASE_URL` pointing directly to production PostgreSQL as `eventsales_migrator`.

Migration guards:

- exact app image digest approved;
- production PostgreSQL healthy;
- production database/roles/default privileges proven;
- backup/rollback decision recorded;
- migration container has no public port;
- migration authorization is one-shot;
- failure preserves logs/container evidence and forbids blind rerun.

The existing PostgreSQL advisory migration lock remains enabled.

### Bootstrap

After migrations and private app readiness:

1. start the private app with temporary bootstrap environment values;
2. explicitly invoke the idempotent admin and source-system bootstrap in the running node;
3. verify bootstrap result without printing secret values;
4. recreate the private app from the same digest without bootstrap admin credentials;
5. re-prove readiness before continuing.

Bootstrap is not coupled to every future deployment.

---

## 13. Image Build and Registry Flow

GitHub Actions builds the production image for `linux/amd64` from an accepted Git commit.

Required image pipeline:

```text
accepted commit
  -> CI build
  -> release/image smoke verification
  -> GHCR push
  -> immutable digest recorded
  -> provenance/SBOM emitted
  -> deployment consumes digest only
```

The Dockerfile builder and runner base images must be digest-pinned for reproducibility. The final image must preserve the non-root EventSales user and normal `bin/event_sales start` command.

The existing source/test CI remains authoritative for code quality; the image workflow adds production artifact verification rather than replacing test/format/security gates.

---

## 14. Private Deployment and Ingress

### Private app state

The first production app container joins both production networks but publishes **no** host port.

Private acceptance must prove:

- process liveness;
- `/ready` semantics via the running node/probe;
- real Ecto/Ash queries through PgBouncer transaction mode;
- prepared statement behavior;
- Oban insert/execute/retry behavior with `Oban.Notifiers.PG`;
- Redis rate-limit ZSET transaction path;
- Redis hot-state SET/GET/SCAN path;
- production ACL denial outside allowed command/key scope;
- PubSub/DNSCluster single-node startup;
- no data-service restarts;
- no D0 changes.

### Loopback ingress

Only after private acceptance may a separate Compose override publish:

```text
127.0.0.1:4100:4000
```

Verification must prove:

- `127.0.0.1:4100` works locally;
- no wildcard/IPv6 public host bind exists;
- no external interface accepts port 4100;
- `/health` returns healthy;
- `/ready` returns ready using correct `Host` and `X-Forwarded-Proto` headers when needed by production SSL enforcement.

Phoenix may continue listening on all interfaces **inside the container**. The security boundary is the Docker host publication to loopback.

---

## 15. OpenLiteSpeed Public Cutover

OpenLiteSpeed remains a separate authority after loopback proof.

Public cutover requirements:

- one approved public `PHX_HOST`;
- upstream `127.0.0.1:4100`;
- correct `Host`, `X-Forwarded-For`, and `X-Forwarded-Proto=https` behavior;
- WebSocket upgrade support for LiveView;
- health/readiness verification before and after routing;
- no direct public Phoenix port;
- explicit rollback to the prior OLS state.

`EVENTSALES_CHECK_ORIGIN` defaults to the HTTPS public host unless a reviewed multi-origin requirement exists.

---

## 16. State Machines

Every lifecycle-bearing D1 resource is fail-closed.

### 16.1 ProductionDataPlane

```text
ABSENT
  -> STAGED
  -> BOOTSTRAPPED
  -> RUNNING
  -> PROVEN
  -> ACCEPTED
```

Guards:

- D0 unchanged;
- exact pinned images;
- exact project/network/volume names;
- fresh secret set;
- no host data-service ports.

Failure from any mutating transition enters `BLOCKED`; no automatic repair/retry is authorized.

### 16.2 AppImage

```text
SOURCE_ACCEPTED
  -> BUILT
  -> VERIFIED
  -> PUSHED
  -> DIGEST_RECORDED
  -> DEPLOYABLE
```

Terminal reject state: `REJECTED`. A rejected digest is never deployed.

### 16.3 MigrationRun

```text
UNAUTHORIZED
  -> AUTHORIZED_ONCE
  -> RUNNING
  -> SUCCEEDED
```

Failure state: `FAILED_FORENSIC`. Rerun requires new review/authority.

Side effects: schema/data migration only. It must not start public ingress.

### 16.4 BootstrapRun

```text
UNAUTHORIZED
  -> AUTHORIZED_ONCE
  -> ADMIN_BOOTSTRAPPED
  -> SOURCE_BOOTSTRAPPED
  -> VERIFIED
  -> BOOTSTRAP_SECRETS_REMOVED
```

Failure preserves the private container and evidence. No public ingress may follow.

### 16.5 RuntimeApp

```text
ABSENT
  -> PRIVATE_CREATED
  -> RUNNING
  -> HEALTHY
  -> READY
  -> PRIVATE_PROVEN
  -> BOOTSTRAP_CREDENTIALS_REMOVED
  -> PRIVATE_ACCEPTED
```

Failure state: `BLOCKED`. Container/log evidence is preserved.

### 16.6 LoopbackIngress

```text
ABSENT
  -> LOOPBACK_PUBLISHED
  -> LOCAL_HEALTHY
  -> EXTERNAL_DENIAL_PROVEN
  -> ACCEPTED
```

### 16.7 OLSRoute

```text
ABSENT
  -> CONFIG_STAGED
  -> UPSTREAM_PROVEN
  -> PUBLIC_ENABLED
  -> POST_CUTOVER_VERIFIED
  -> ACCEPTED
```

Failure after public enable transitions to `ROLLBACK_REQUIRED`; rollback is explicit, not improvised.

---

## 17. Invariants and Data Integrity Rules

1. D0 remains unchanged throughout D1.
2. `event_sales_prod` is distinct from `eventsales_proof`.
3. Production credentials are fresh and never reuse D0 proof bytes.
4. Runtime DB access is PgBouncer-only.
5. Direct PostgreSQL is migration/backup/maintenance only.
6. Runtime DDL remains denied.
7. Migrator-owned future objects automatically grant required runtime/backup privileges.
8. No data service publishes a host port.
9. Redis production runtime is restricted to `eventsales:prod:*` and accepted command families.
10. Webhook degraded Redis buffering remains disabled until durability is designed and approved.
11. App startup never auto-migrates.
12. A migration failure is never followed by blind application start.
13. Bootstrap admin password does not persist in the final runtime environment.
14. App image is deployed by immutable digest.
15. Public OLS routing cannot precede private runtime and loopback acceptance.
16. No large analytics table scan is introduced on peak paths; cached/materialized/read-replica strategies are required before high-scale analytics claims.
17. Hot state remains bounded in ETS/GenServers; warm state remains Redis-backed; PostgreSQL is durable truth.
18. Heavy work remains asynchronous through Oban; request paths do not perform unbounded background work synchronously.

---

## 18. Performance and Scaling Review

### Hot / warm / cold

- **Hot:** ETS, GenServers, in-node caches, Phoenix PubSub.
- **Warm:** dedicated Redis for rate-limit ZSETs and hot-state snapshot cache.
- **Cold/durable:** PostgreSQL.
- **Browser/CDN:** existing browser storage patterns remain app-owned; static asset CDN/OLS caching is handled at ingress/cutover layers.

### High concurrency

- Ecto app pool: 20 on the first node.
- PgBouncer client capacity: 64.
- PgBouncer backend cap: 16.
- PostgreSQL remains capped at 2 CPU / 3 GiB initially.
- Redis rate limiting uses sorted sets and TTLs rather than database writes.
- readiness uses ETS snapshots rather than one DB call per probe.
- Oban performs heavy/async work.
- PubSub/LiveView push remains the real-time update model; polling is not introduced.

### Flash-sale readiness

D1 creates a safe first production node but does **not** by itself certify 100k-concurrent-user readiness. Before that claim is made, later scaling work must prove:

- horizontal EventSales nodes;
- DNSCluster membership and PubSub fan-out;
- PgBouncer capacity under load;
- Redis rate-limit/hot-state load;
- read replicas/materialized aggregates for analytics/dashboard reads;
- queue/rate-limit behavior during traffic spikes;
- thundering-herd/cache-stampede protections;
- CDN/static caching;
- sub-100ms hot-path API targets and sub-5s checkout-adjacent p99 where EventSales participates in those flows.

D1 must not make architectural choices that block those later requirements.

---

## 19. Security and Multi-Tenant Review

EventSales is treated as one production service boundary. No cross-project Docker network sharing is allowed except the explicit app-to-production-data external networks.

Security requirements:

- no production source build on VPS;
- no secret values in Git, image layers, command arguments, logs, or review reports;
- least-privilege DB roles;
- least-privilege Redis ACL;
- non-root containers;
- read-only root filesystems where supported;
- capabilities dropped;
- `no-new-privileges`;
- loopback-only host app publication;
- OLS remains the public TLS/reverse-proxy boundary;
- admin/internal routes retain existing application authorization and production internal-tool disabling;
- application runtime never receives migrator/bootstrap/backup database credentials.

If future EventSales tenancy becomes multi-tenant, database row isolation and Redis key namespace isolation require a separate domain-level tenancy design; D1 must not claim multi-tenant isolation that the current application model does not provide.

---

## 20. Failure Modes and Required Behavior

| Failure | Required behavior |
|---|---|
| Main/review authority moves before implementation | stop and rebase/review before work |
| D0 object/state changes | stop; do not continue D1 |
| Production secret leaks to output | stop; rotate affected production secret before continuing |
| Production bootstrap privilege mismatch | stop before migrations |
| Migrator cannot create required functions/extensions | stop; do not elevate runtime role |
| Prepared statements fail through transaction pool | stop; investigate evidence before changing Ecto/PgBouncer strategy |
| Oban notifier fails without PostgreSQL LISTEN | stop; do not revert silently to session pooling |
| Redis ACL denies legitimate rate-limit/hot-state operation | stop; add only the proven missing command |
| Redis ACL permits unrelated dangerous commands | block ACL acceptance |
| Migration fails | preserve forensic evidence; no blind rerun; no app start |
| App fails private readiness | preserve app/logs; no host port |
| Bootstrap fails | preserve private state; no public ingress |
| Port 4100 is externally reachable | block loopback acceptance |
| OLS WebSocket/proxy header proof fails | rollback public-route attempt |
| Data service restarts unexpectedly | stop and investigate before proceeding |

---

## 21. Recommended Repository Structure

D1 implementation should converge on the following boundaries:

```text
.github/workflows/
└── eventsales-image.yml              # immutable GHCR production image

config/
├── config.exs                        # Oban notifier default/production-safe config
├── prod.exs
└── runtime.exs                       # pool/runtime/clustering production config

lib/event_sales/
├── application.ex                    # existing DNSCluster/PubSub supervision
└── release.ex                        # migration helper; no automatic startup migration

deploy/vps/
├── README.md                         # deployment authority and operator flow
├── data-plane/
│   ├── compose.yaml                  # postgres/pgbouncer/redis only
│   ├── pgbouncer.ini                 # non-secret pool behavior
│   ├── redis-users.acl.template      # usernames/permissions, no secret values
│   └── scripts/                      # bounded staging/probe helpers
└── app/
    ├── compose.yaml                  # private app, no host port
    ├── compose.loopback.yaml         # 127.0.0.1:4100:4000 only
    └── scripts/                      # private/readiness/ingress probes

docs/deployment/
├── vps-production-data-plane.md
├── vps-production-app.md
└── vps-ols-cutover.md

docs/superpowers/specs/
└── 2026-10-20-d1-vps-production-architecture-design.md
```

Naming rules:

- Compose project: `eventsales-prod` for data plane.
- Compose project: `eventsales-app` for application.
- Database: `event_sales_prod`.
- Runtime Redis namespace: `eventsales:prod:*`.
- Host app ingress: `127.0.0.1:4100`.
- Container app port: `4000`.
- Do not use `proof`, `test`, or `d0` in permanent production resource names.

---

## 22. D1 Phase Gates

### D1-B — Production data-plane candidate

Create reviewed configuration/artifacts only. No live VPS mutation until authority review.

### D1-C — Production data-plane proof

Create and prove new `eventsales-prod` PostgreSQL/PgBouncer/Redis in parallel with frozen D0.

### D1-D — Application transaction-pooling hardening

Change repository runtime architecture for transaction-pool-safe prepared statements, `Oban.Notifiers.PG`, clustering config, and production tests/docs.

### D1-E — Immutable image pipeline

Build/test/push GHCR image and record digest.

### D1-F — Production migrations

Run one-shot direct migration against `event_sales_prod`.

### D1-G — Private application deployment

Start app with no host port.

### D1-H — Private runtime proof and bootstrap cleanup

Prove database, Oban, Redis, PubSub/readiness; perform bootstrap; recreate without bootstrap admin password.

### D1-I — Loopback ingress

Publish and prove `127.0.0.1:4100:4000` only.

### D1-J — OpenLiteSpeed upstream proof

Stage proxy behavior without assuming public acceptance.

### D1-K — Public cutover

Enable public route only after all previous gates pass.

Each phase has a distinct review/authorization boundary. Later phases never retroactively authorize earlier failed work.

---

## 23. Verification Strategy

Implementation must include automated repository tests plus bounded production-like probes.

Minimum repository tests:

- runtime config selects `Oban.Notifiers.PG` in production target;
- production config keeps `DATABASE_URL` and `DIRECT_DATABASE_URL` responsibilities separate;
- app pool size parses/uses the production setting;
- Redis rate limiter commands are represented in ACL tests;
- hot-state Redis commands are represented in ACL tests;
- degraded webhook buffer remains off by default;
- release migration URL preference remains direct-first;
- no normal startup migration is introduced;
- Docker/Compose configuration validates with exact expected networks/security/ports;
- production image builds and release smoke passes.

Production-like proofs:

- PgBouncer transaction reuse;
- prepared statement reuse across transaction-pooled backends;
- runtime DML allowed and DDL denied;
- direct runtime PostgreSQL login denied;
- Oban success + retry worker path;
- Oban notifier/queue behavior without Postgres `LISTEN` dependency;
- Redis ZSET rate limiter;
- Redis hot-state snapshot write/restore;
- Redis denied command/key cases;
- private app readiness;
- loopback-only ingress;
- OLS WebSocket and forwarded-proto behavior.

---

## 24. Rollback Model

### Before public cutover

Rollback is removal/rejection of the new production candidate only. D0 remains untouched.

### Application rollback

Deploy the previously accepted image digest. Do not rebuild an older source tree on the VPS.

### Database rollback

Schema rollback is never automatic. A failed migration enters forensic review. Before any reviewed down migration, confirm backup state and application/schema compatibility.

### OLS rollback

Restore the exact previously captured OLS configuration and verify the previous public behavior. OLS rollback must not alter the EventSales data plane.

---

## 25. Non-Goals / Deferred Work

D1 does not implement:

- PostgreSQL analytics read replicas;
- multi-host EventSales clustering;
- Redis persistence/durable webhook buffer;
- CDN configuration beyond public-cutover compatibility;
- full 100k-concurrency certification;
- automatic data-plane failover;
- Kubernetes/Nomad orchestration;
- multi-tenant domain isolation.

These are future scaling/reliability slices. D1 must leave clean boundaries for them.

---

## 26. Acceptance Criteria for the D1 Architecture

The design is implementation-ready when the implementation plan can enforce all of the following without guessing:

```text
D0_PROOF=FROZEN
PRODUCTION_DATA_PROJECT=eventsales-prod
PRODUCTION_APP_PROJECT=eventsales-app
PRODUCTION_DATABASE=event_sales_prod
PRODUCTION_SECRETS=FRESH
D0_SECRET_REUSE=NO

PGBOUNCER_POOL_MODE=transaction
PGBOUNCER_MAX_CLIENT_CONN=64
PGBOUNCER_DEFAULT_POOL_SIZE=12
PGBOUNCER_RESERVE_POOL_SIZE=4
PGBOUNCER_MAX_DB_CONNECTIONS=16
PGBOUNCER_MAX_USER_CONNECTIONS=16
PGBOUNCER_MAX_PREPARED_STATEMENTS=200

APP_DB_POOL_SIZE=20
OBAN_NOTIFIER=Oban.Notifiers.PG
DNS_CLUSTER=EXISTING_APPLICATION_BOUNDARY

REDIS_NAMESPACE=eventsales:prod:*
WEBHOOK_REDIS_BUFFER_ENABLED=false
WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED=false

APP_IMAGE=IMMUTABLE_GHCR_DIGEST
APP_PRIVATE_FIRST=YES
HOST_LOOPBACK=127.0.0.1:4100:4000
PUBLIC_OLS_LAST=YES

APP_DEPLOYMENT_AUTHORIZED=NO
VPS_MUTATION_AUTHORIZED=NO
OLS_CHANGE_AUTHORIZED=NO
```

---

## 27. Authority After This Spec

Approval of this document authorizes only creation of the implementation plan.

It does **not** authorize:

- production secret generation;
- creation of `eventsales-prod`;
- PgBouncer or Redis mutation;
- application code changes;
- GHCR publication;
- migrations;
- application start;
- port publication;
- OpenLiteSpeed/CyberPanel changes.

Those actions require the implementation plan and the later phase-specific authorities defined above.
