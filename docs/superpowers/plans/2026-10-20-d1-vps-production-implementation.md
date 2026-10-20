# EventSales D1 VPS Production Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Productionize EventSales on the existing VPS without mutating the accepted D0 proof, using a parallel production PostgreSQL/PgBouncer/Redis data plane, transaction-pooled runtime DB access, an immutable application image, private-first application verification, loopback ingress, and a separately authorized OpenLiteSpeed cutover.

**Architecture:** Keep `eventsales-d0-proof` frozen. Build a new `eventsales-prod` data-plane Compose project and a separate `eventsales-app` application project. Runtime DB traffic uses PgBouncer transaction pooling; migrations use direct PostgreSQL; Oban notifications use `Oban.Notifiers.PG`; production Redis is least-privilege under `eventsales:prod:*`; the application is deployed by immutable GHCR digest, proven privately, then published only on `127.0.0.1:4100` before OLS cutover.

**Tech Stack:** Elixir 1.19.3, Erlang/OTP 28.1.1, Phoenix 1.8, Ecto/Postgrex, Ash/AshPostgres, Oban 2.24, Redix 1.5, DNSCluster, Docker/Compose, PostgreSQL 18.6, PgBouncer 1.26.1, Redis 8.10.2, GitHub Actions/GHCR, OpenLiteSpeed.

**Spec:** `docs/superpowers/specs/2026-10-20-d1-vps-production-architecture-design.md`

**Authority base:** `main` at `13ca53d5e1671b2fde4ab21e7e2725a5a27bb2d2`.

**Planning status:** User approved the D1 architecture on 2026-10-20. This plan grants **no implementation, VPS mutation, secret-generation, deployment, or OLS authority** by itself.

## Global Constraints

- D0 remains frozen: project `eventsales-d0-proof`, final accepted boundary `3 containers / 2 networks / 1 volume`.
- Production is a new data-plane project named `eventsales-prod`; application project is `eventsales-app`.
- Production database is `event_sales_prod`; never convert `eventsales_proof` into production.
- Production secrets are fresh; never copy or rotate D0/R16 evidence credentials into production.
- Runtime DB role is `eventsales_runtime`; migrations use `eventsales_migrator`; backups use `eventsales_backup`.
- Runtime database path is `DATABASE_URL -> pgbouncer:6432/event_sales_prod` with `POOL_SIZE=20`.
- Long-running app must not receive `DIRECT_DATABASE_URL`, migrator password, PostgreSQL bootstrap password, or backup password.
- PgBouncer stays in transaction mode with `max_client_conn=64`, `default_pool_size=12`, `reserve_pool_size=4`, `max_db_connections=16`, `max_user_connections=16`, `max_prepared_statements=200`.
- Do not add `prepare: :unnamed` unless the real transaction-pooling proof fails and a separate evidence-based review authorizes it.
- Production Oban notifier is `Oban.Notifiers.PG`; database-backed peer/leadership remains unchanged unless evidence requires otherwise.
- The first production node runs distributed Erlang from day one and uses the existing DNSCluster boundary.
- Production Redis runtime keys are limited to `eventsales:prod:*`; webhook degraded buffering stays disabled and durability unaccepted.
- Initial app resources: 4 CPUs, 2 GiB memory, PIDs limit 512.
- Initial PostgreSQL resources: 2 CPUs, 3 GiB memory.
- Initial PgBouncer resources: 0.5 CPU, 128 MiB memory.
- Initial Redis resources: 0.5 CPU, 512 MiB container memory, 384 MiB Redis maxmemory, `noeviction`, persistence disabled.
- Production data services publish no host ports.
- Private app deployment publishes no host port.
- Loopback ingress is a later overlay publishing exactly `127.0.0.1:4100:4000`.
- OLS configuration is a separate final gate; do not combine it with app deployment.
- Production image must be deployed by immutable `ghcr.io/jcschoeman96/eventsales@sha256:<64-hex>` reference; production Compose must contain no `build:` directive.
- Normal app startup must not auto-run migrations.
- Use existing `/health` liveness and ETS-backed `/ready` readiness; do not add per-request database polling.
- No large analytics table scans at peak; hot state remains ETS/GenServer, warm state Redis, durable truth PostgreSQL, heavy work Oban.
- No polling where Phoenix PubSub/LiveView push already owns real-time propagation.
- Read replicas/materialized/cached aggregates remain a later scaling gate before claiming 100k-concurrent-user analytics readiness.
- Every one-shot production mutation has an explicit authorization boundary and terminal failure state; no blind reruns.
- Never print secret values, credentials embedded in URLs, release cookie values, or secret hashes in operational evidence.

## Review Focus

1. **Transaction-pool semantic leaks:** runtime code must not reintroduce PostgreSQL session-dependent behavior (`LISTEN`, session advisory assumptions, temp-table/session state) through `DATABASE_URL`; tests/docs must pin Oban to `Oban.Notifiers.PG` and the live private proof must exercise repeated Ecto/Ash/Oban work through PgBouncer.
2. **Credential boundary regression:** final app runtime must not contain direct/migrator/bootstrap/backup credentials; deployment contract checks and VPS inspection must prove only runtime credentials remain.
3. **Redis ACL under/over-permission:** enabled production adapters must work with the explicit sorted-set/transaction/scan command family while unrelated commands and out-of-prefix keys remain denied.
4. **Forensic loss on one-shot failures:** migration/bootstrap/probe containers and logs must be preserved on failure; automatic `--rm`, automatic retry, and destructive cleanup are forbidden until review.
5. **Ingress authority collapse:** private app, loopback publication, OLS upstream validation, and public cutover must remain separate transitions; tests/static contract checks must reject a host port in the private Compose file and reject data-service host ports everywhere.

---

# 1. File / Responsibility Map

## Existing files to modify

| Path | Responsibility after D1 |
|---|---|
| `config/config.exs` | Default application/Oban topology; change notifier to `Oban.Notifiers.PG` while keeping queue ownership and database peer semantics intact. |
| `config/runtime.exs` | Production DB pool size, Redis feature wiring, DNSCluster query, production-safe runtime values; keep migrations separate from normal startup. |
| `config/prod.exs` | Production compile-time security/runtime policy, including disabling runtime tzdata auto-update if supported by current tzdata configuration contract. |
| `lib/event_sales/release.ex` | Separate migration and bootstrap release operations; retain Railway compatibility without making VPS startup auto-migrate. |
| `lib/event_sales/maintenance/production_smoke.ex` | Keep public/HTTPS production smoke role; do not repurpose it into the private pre-ingress smoke. |
| `test/event_sales/oban_topology_test.exs` | Pin notifier/queue topology to the approved transaction-pooling model. |
| `test/event_sales/release_test.exs` | Pin migration/bootstrap ordering, redaction, and separate release entrypoints. |
| `Dockerfile` | Build the immutable OTP release, preserve non-root runner, add reproducible image metadata; no deployment-time source build assumptions. |
| `.dockerignore` | Ensure build context is minimal without excluding files required by the image build. |
| `.github/workflows/ci.yml` | Add static D1 deployment contract checks without publishing images from PRs. |
| `docs/architecture/db-topology.md` | Replace historical session-pooling production authority with approved transaction-pooling production authority while preserving historical context where needed. |
| `docs/architecture/oban-pgbouncer.md` | Document `Oban.Notifiers.PG`, transaction pooling, first-node distribution, and later multi-node gate. |
| `docs/deployment/pgbouncer.md` | Document production pool values and prepared-statement proof. |
| `docs/deployment/runtime-config.md` | Split runtime, migration, bootstrap and smoke environment contracts; remove VPS guidance that builds on-host. |
| `docs/deployment/migrations-and-release.md` | Document one-shot migration, separate bootstrap, failure preservation, rollback/backup prerequisite. |
| `compose.yaml` | Keep local/developer semantics or clearly mark as local-only; it must not masquerade as VPS production authority. |

## New files to create

| Path | Responsibility |
|---|---|
| `rel/env.sh.eex` | Release node identity/distribution defaults for production containers, deriving a unique node name from container hostname and requiring externally supplied release cookie. |
| `lib/event_sales/maintenance/private_runtime_smoke.ex` | Secret-safe, bounded private proof of runtime DB/PgBouncer/Oban/Redis/readiness behavior before any host port exists. |
| `test/event_sales/maintenance/private_runtime_smoke_test.exs` | Unit contract for private smoke ordering, safe output, failure redaction and required environment guards. |
| `.github/workflows/event-sales-image.yml` | Build/test/push immutable EventSales image to GHCR from an accepted commit and expose resulting digest/provenance. |
| `scripts/check_vps_deploy_contract.sh` | Static fail-closed repository gate for production Compose/image/runtime invariants. |
| `deploy/vps/data-plane/compose.yaml` | Production PostgreSQL/PgBouncer/Redis Compose definition only. |
| `deploy/vps/data-plane/README.md` | Production data-plane staging, secret, lifecycle and STOP rules. |
| `deploy/vps/data-plane/templates/pgbouncer.ini.template` | Non-secret structural PgBouncer template with exact approved pool values; secret fields are rendered outside Git. |
| `deploy/vps/data-plane/templates/redis-users.acl.template` | Structural ACL template defining users/prefix/command families without real password values. |
| `deploy/vps/data-plane/scripts/generate-secrets.sh` | Root-only fresh production secret generation and safe file-mode setup; prints metadata only, never values/hashes. |
| `deploy/vps/data-plane/scripts/render-runtime-config.sh` | Render PgBouncer/Redis secret-bearing runtime config from protected secret files without stdout leakage. |
| `deploy/vps/data-plane/scripts/bootstrap-postgres.sh` | One-shot production role/database/default-privilege bootstrap against the new production PostgreSQL only. |
| `deploy/vps/data-plane/scripts/probe-postgres.sh` | Read-only verification of DB/role/privilege/default-privilege state. |
| `deploy/vps/data-plane/scripts/probe-pgbouncer.sh` | Bounded runtime-auth, direct-auth denial, DML/DDL, pooling/prepared-statement proof support. |
| `deploy/vps/data-plane/scripts/probe-redis.sh` | ACL prefix/command/maxmemory/noeviction/persistence proof. |
| `deploy/vps/app/compose.yaml` | Private application Compose definition using immutable digest and production external networks, with no host ports. |
| `deploy/vps/app/compose.ingress.yaml` | Loopback-only ingress overlay publishing `127.0.0.1:4100:4000`. |
| `deploy/vps/app/README.md` | App staging, migration, bootstrap, private proof, loopback and OLS gate sequence. |
| `deploy/vps/app/scripts/probe-private.sh` | Host-side bounded verification of app container security, network topology and private runtime smoke result. |
| `deploy/vps/app/scripts/probe-loopback.sh` | Verify localhost `4100`, HTTP `/health` and `/ready`, and absence of non-loopback publication. |
| `docs/deployment/vps-production.md` | Human operational runbook tying the repository artifacts to D1-B through D1-K lifecycle gates. |

---

# 2. Phase / Slice Design

Implementation is intentionally split into five repository slices before any VPS mutation. Each slice is separately reviewable and must merge before the next slice that depends on it.

## Slice R1 — Transaction-Pooling Runtime Compatibility

**Outcome:** EventSales runtime configuration and documentation are compatible with PgBouncer transaction pooling without using `LISTEN/NOTIFY` for Oban.

### Task R1.1: Switch Oban notifier authority

**Files:**
- Modify: `config/config.exs`
- Modify: `test/event_sales/oban_topology_test.exs`
- Modify: `docs/architecture/oban-pgbouncer.md`
- Modify: `docs/architecture/db-topology.md`
- Modify: `docs/deployment/pgbouncer.md`

**Interfaces:**
- Consumes: existing `EventSales.Repo`, Oban queues and database-backed peer semantics.
- Produces: `Application.fetch_env!(:event_sales, Oban)[:notifier] == Oban.Notifiers.PG`.

- [ ] **Step 1: Write/adjust the failing notifier contract test.**
  - Assert notifier is `Oban.Notifiers.PG`.
  - Assert queue concurrency values are unchanged.
  - Assert the task does not change the Oban engine or peer unless already explicitly configured.
- [ ] **Step 2: Run `mix test test/event_sales/oban_topology_test.exs`.**
  - Expected before implementation: FAIL because notifier is `Oban.Notifiers.Postgres`.
- [ ] **Step 3: Make the minimal config change in `config/config.exs`.**
  - Replace only the notifier selection; do not change queue values or introduce new Oban plugins here.
- [ ] **Step 4: Update the three topology documents.**
  - Production authority: transaction pooling + `Oban.Notifiers.PG`.
  - Preserve historical Railway/session-pooling statements only when explicitly labeled historical, not current production authority.
  - Explicitly state that `LISTEN/NOTIFY` through pooled runtime is forbidden.
- [ ] **Step 5: Re-run the targeted test and `mix format --check-formatted`.**
  - Expected: PASS.
- [ ] **Step 6: Commit only R1.1 files.**

### Task R1.2: Pin production DB pool and first-node cluster runtime

**Files:**
- Modify: `config/runtime.exs`
- Create: `rel/env.sh.eex`
- Modify: `docs/deployment/runtime-config.md`
- Test: `test/event_sales/production_runtime_contract_test.exs` (create)

**Interfaces:**
- Consumes: `DATABASE_URL`, `POOL_SIZE`, `DNS_CLUSTER_QUERY`, release `HOSTNAME`, `RELEASE_COOKIE`.
- Produces: production default pool size `20`; DNSCluster query supplied by deployment; distributed release node identity derived uniquely per container.

- [ ] **Step 1: Add a production-runtime contract test.**
  - Pin default production `POOL_SIZE` to `20`.
  - Pin the release env template to `RELEASE_DISTRIBUTION=name` and a node name derived from `${HOSTNAME}` rather than a fixed node name.
  - Pin that the release cookie is externally supplied and not embedded in repository text.
- [ ] **Step 2: Run the targeted test.**
  - Expected before implementation: FAIL because pool default is `10` and `rel/env.sh.eex` is absent.
- [ ] **Step 3: Update `config/runtime.exs` minimally.**
  - Change only the production default pool size from `10` to `20`; retain `POOL_SIZE` override support.
  - Keep `DATABASE_URL` as the runtime URL and `DIRECT_DATABASE_URL` as migration metadata only.
- [ ] **Step 4: Add `rel/env.sh.eex`.**
  - Derive a unique long node name from container hostname.
  - Do not generate or print a cookie.
  - Fail cleanly when required release-cookie input is absent in production execution.
- [ ] **Step 5: Update runtime docs and run the targeted test.**
  - Expected: PASS.
- [ ] **Step 6: Commit only R1.2 files.**

### Task R1.3: Prove application-level notifier behavior remains functional

**Files:**
- Modify: `test/event_sales/maintenance/production_smoke_test.exs` only if an existing notifier assertion must be generalized.
- Modify: `lib/event_sales/maintenance/production_smoke.ex` only if it currently emits the old notifier name as authority.

**Interfaces:**
- Produces: existing Oban success/retry smoke remains notifier-agnostic and secret-safe.

- [ ] **Step 1: Identify any test or smoke output pinned to `Oban.Notifiers.Postgres`.**
- [ ] **Step 2: Add/adjust the smallest assertion needed to accept `Oban.Notifiers.PG` without weakening the job success/retry proof.**
- [ ] **Step 3: Run `mix test test/event_sales/maintenance/production_smoke_test.exs test/event_sales/oban_topology_test.exs`.**
- [ ] **Step 4: Commit only if a code/test change was necessary; otherwise record `NO_CHANGE_REQUIRED` in the PR evidence.**

**Slice R1 STOP:** If `Oban.Notifiers.PG` does not work in the repository test environment, do not fall back to Postgres notifier and do not change PgBouncer mode. Diagnose whether the failure is node distribution, notifier startup, test isolation, or Oban-version behavior first.

---

## Slice R2 — Release Migration / Bootstrap Separation

**Outcome:** VPS migrations and first-production bootstrap are separately invokable, secret-safe lifecycle transitions; normal app startup still runs neither.

### Task R2.1: Add a separate release bootstrap entrypoint

**Files:**
- Modify: `lib/event_sales/release.ex`
- Modify: `test/event_sales/release_test.exs`
- Modify: `docs/deployment/migrations-and-release.md`

**Interfaces:**
- Produces: `EventSales.Release.bootstrap(opts \\ []) :: :ok`.
- Existing: `EventSales.Release.migrate(opts \\ [])` remains direct-URL migration primitive.
- Compatibility: `migrate_and_bootstrap/1` may remain for Railway, but should compose the separate operations rather than define VPS authority.

- [ ] **Step 1: Write failing tests for `bootstrap/1`.**
  - It starts/uses the application only as required by current bootstrap APIs.
  - Admin bootstrap happens before source-system bootstrap.
  - Migration is not invoked by `bootstrap/1`.
  - Failure in admin bootstrap prevents source bootstrap.
  - Output contains safe labels only.
- [ ] **Step 2: Run `mix test test/event_sales/release_test.exs`.**
  - Expected: FAIL because `bootstrap/1` does not exist.
- [ ] **Step 3: Implement the minimum separate release bootstrap function.**
  - Reuse existing `AdminBootstrap` and `SourceSystemBootstrap`; do not duplicate domain logic.
  - Keep `migrate/1` unchanged except where composition requires a small refactor.
- [ ] **Step 4: Make `migrate_and_bootstrap/1` delegate to the separated primitives while preserving Railway behavior/tests.**
- [ ] **Step 5: Update deployment docs to distinguish VPS one-shot migration, temporary bootstrap-authorized app, final runtime recreation, and Railway compatibility path.**
- [ ] **Step 6: Run targeted tests and `mix format --check-formatted`.**
- [ ] **Step 7: Commit only R2.1 files.**

### Task R2.2: Add credential-boundary tests/documentation

**Files:**
- Modify: `test/event_sales/release_test.exs`
- Modify: `docs/deployment/runtime-config.md`

- [ ] **Step 1: Add tests proving migration errors redact credentials and bootstrap errors do not echo secret values supplied via environment.**
- [ ] **Step 2: Document three disjoint environment classes: runtime, migration, bootstrap.**
- [ ] **Step 3: Explicitly remove `DIRECT_DATABASE_URL` and bootstrap variables from the documented final long-running runtime variable set.**
- [ ] **Step 4: Run release tests.**
- [ ] **Step 5: Commit.**

**Slice R2 STOP:** Do not change domain bootstrap behavior, source-system matching semantics, or migration ordering beyond what is required for separation. Any non-idempotent bootstrap evidence blocks D1.

---

## Slice R3 — Private Runtime Smoke + Immutable Image

**Outcome:** A reviewed image can be built/published immutably, and the running private app can prove DB/PgBouncer/Oban/Redis behavior without public ingress or bootstrap-secret leakage.

### Task R3.1: Create `PrivateRuntimeSmoke`

**Files:**
- Create: `lib/event_sales/maintenance/private_runtime_smoke.ex`
- Create: `test/event_sales/maintenance/private_runtime_smoke_test.exs`

**Interfaces:**
- Produces: `EventSales.Maintenance.PrivateRuntimeSmoke.config!(env \\ System.get_env()) :: map()`.
- Produces: `EventSales.Maintenance.PrivateRuntimeSmoke.run!(opts \\ []) :: :ok`.
- Uses existing `EventSales.Repo`, Oban worker smoke primitives, Redix adapters and `EventSales.Health.DatabaseReadiness`.

**Required private checks:**
1. application is running;
2. no pending migrations;
3. Repo identity reports runtime user / `event_sales_prod` / server port `5432` through PgBouncer;
4. repeated prepared Ecto/Postgrex queries succeed across transactions;
5. representative Ash reads succeed;
6. Oban success and retry jobs complete with retry evidence;
7. configured notifier is `Oban.Notifiers.PG`;
8. webhook rate-limit Redis path succeeds using its real ZSET/transaction commands;
9. hot-state snapshot Redis path succeeds using its real `SET PX`/`GET` path when enabled;
10. database readiness snapshot reaches `:ready` without direct request-side DB polling;
11. webhook degraded buffer remains disabled/unaccepted;
12. output contains no URL credentials, passwords, cookie, tokens or raw secret-bearing exceptions.

- [ ] **Step 1: Write unit tests using injected named checks, following the existing `ProductionSmoke` safe-output pattern.**
- [ ] **Step 2: Add failure-redaction tests with secret-bearing synthetic errors.**
- [ ] **Step 3: Add config guard tests for required private runtime conditions, especially production DB name/namespace and disabled webhook buffer.**
- [ ] **Step 4: Run the targeted test and confirm failure before module creation.**
- [ ] **Step 5: Implement only the bounded private checks above; reuse existing app adapters rather than duplicate Redis/Oban logic.**
- [ ] **Step 6: Run targeted tests.**
- [ ] **Step 7: Commit.**

### Task R3.2: Harden immutable image metadata

**Files:**
- Modify: `Dockerfile`
- Modify: `config/prod.exs` if tzdata auto-update must be disabled there.
- Modify: `.dockerignore` only if required build inputs are currently excluded.
- Test: `scripts/check_vps_deploy_contract.sh` is added in R4 and will pin image rules; for this task use `docker build` as the direct verification.

- [ ] **Step 1: Build current image from the accepted source and record baseline success.**
- [ ] **Step 2: Add OCI source/revision labels through build args; do not bake secrets or deployment env into layers.**
- [ ] **Step 3: Keep final `USER eventsales` and release-only runner image.**
- [ ] **Step 4: Disable tzdata runtime auto-update through application config if current dependency supports the configured switch; do not add mutable timezone downloads to the container.**
- [ ] **Step 5: Build image again with a synthetic Git SHA and inspect labels/user/CMD.**
- [ ] **Step 6: Run `mix quality.fast` and commit.**

### Task R3.3: Add GHCR image workflow

**Files:**
- Create: `.github/workflows/event-sales-image.yml`

**Workflow contract:**
- Trigger on accepted `main` commits and manual dispatch; never publish from an untrusted PR context.
- Use repository `GITHUB_TOKEN` with minimal `contents: read`, `packages: write`, and attestations/id-token permissions only if provenance generation requires them.
- Build the repository `Dockerfile` for `linux/amd64` initially.
- Tag by immutable commit SHA plus optional human tag; deployment authority uses digest, never tag.
- Push `ghcr.io/jcschoeman96/eventsales`.
- Enable BuildKit provenance/SBOM attestations where supported.
- Emit image digest in job summary/artifact without exposing secrets.
- Do not deploy from the workflow.

- [ ] **Step 1: Add workflow syntax and permissions.**
- [ ] **Step 2: Add build args for source/revision metadata.**
- [ ] **Step 3: Ensure no repository/production secret is required to build the image.**
- [ ] **Step 4: Validate workflow YAML and locally build the same Dockerfile.**
- [ ] **Step 5: Commit.**

**Slice R3 STOP:** A mutable image tag alone is never sufficient deployment evidence. If GHCR digest/provenance cannot be obtained, stop before VPS app staging.

---

## Slice R4 — Versioned VPS Deployment Contract

**Outcome:** Repository contains a secret-free, statically testable production data-plane/app deployment definition and probes, without creating anything on the VPS.

### Task R4.1: Add production data-plane Compose

**Files:**
- Create: `deploy/vps/data-plane/compose.yaml`
- Create: `deploy/vps/data-plane/README.md`
- Create: `deploy/vps/data-plane/templates/pgbouncer.ini.template`
- Create: `deploy/vps/data-plane/templates/redis-users.acl.template`

**Compose contract:**
- Logical services: `postgres`, `pgbouncer`, `redis` only.
- Logical networks: `eventsales_data` with `internal: true`; `eventsales_edge` with `internal: false` even though data services do not join it yet.
- Logical volume: `postgres_data`.
- Exact pinned images from the approved spec.
- No `container_name` unless an operational proof establishes a need.
- No data-service `ports:` entries.
- PostgreSQL only data network, 2 CPUs / 3 GiB.
- PgBouncer only data network, UID/GID `65532:65532`, read-only rootfs, 0.5 CPU / 128 MiB, all capabilities dropped, no-new-privileges.
- Redis only data network, UID/GID `65532:65532`, read-only rootfs, 0.5 CPU / 512 MiB, maxmemory 384 MiB, `noeviction`, persistence disabled, all capabilities dropped, no-new-privileges.
- Healthchecks must use commands available in each pinned image and must not require adding packages at runtime.
- Secret-bearing files are mounted read-only from protected host paths or Compose secret file references; no literal secrets in YAML.

- [ ] **Step 1: Create the structural Compose and templates with placeholders only.**
- [ ] **Step 2: Document exact project name `eventsales-prod` and expected final data-plane boundary `3/2/1`.**
- [ ] **Step 3: Document that D0 networks/volume are never external dependencies of production.**
- [ ] **Step 4: Validate with `docker compose --project-name eventsales-prod --env-file /dev/null -f deploy/vps/data-plane/compose.yaml config` using only safe fixture paths/values.**
- [ ] **Step 5: Commit.**

### Task R4.2: Add safe production secret/config preparation scripts

**Files:**
- Create: `deploy/vps/data-plane/scripts/generate-secrets.sh`
- Create: `deploy/vps/data-plane/scripts/render-runtime-config.sh`

**Interfaces:**
- `generate-secrets.sh <absolute-target-dir>` creates fresh production secret files only in an absent, root-owned target directory.
- `render-runtime-config.sh <absolute-secret-dir>` renders `pgbouncer.ini`, `pgbouncer_users.txt`, and `redis-users.acl` from protected inputs without printing secret values/hashes.

**Required secret files:**
- `postgres_bootstrap_password`
- `eventsales_migrator_password`
- `eventsales_runtime_server_password`
- `eventsales_runtime_client_password`
- `eventsales_backup_password`
- `redis_runtime_password`
- `redis_stats_password`
- generated secret-bearing `pgbouncer.ini`
- generated `pgbouncer_users.txt`
- generated `redis-users.acl`

- [ ] **Step 1: Add shell tests/check mode or a temporary-directory dry run that asserts owner/mode/length without printing content.**
- [ ] **Step 2: Implement fail-closed path checks: absolute path, target absent for generation, no symlink traversal, umask `077`.**
- [ ] **Step 3: Generate cryptographically random credentials with a single documented format; do not reuse D0 bytes.**
- [ ] **Step 4: Render PgBouncer exact pool values and Redis ACL exact namespace/commands.**
- [ ] **Step 5: Verify scripts with `bash -n` and temp-dir dry run; inspect that stdout contains metadata only.**
- [ ] **Step 6: Commit.**

### Task R4.3: Add production PostgreSQL bootstrap + read-only proof

**Files:**
- Create: `deploy/vps/data-plane/scripts/bootstrap-postgres.sh`
- Create: `deploy/vps/data-plane/scripts/probe-postgres.sh`

**Bootstrap state transition:** `ABSENT -> BOOTSTRAPPED`; one-shot only.

**Bootstrap invariants:**
- database `event_sales_prod`;
- roles `eventsales_migrator`, `eventsales_runtime`, `eventsales_backup` with connection limits `2/20/2` respectively;
- migrator owns DB/application objects;
- runtime has connect/schema/DML/sequence/function rights but no DDL ownership;
- backup has connect/schema/select rights;
- default privileges for future migrator-created tables, sequences, functions;
- remove unintended public create privilege;
- no app migrations here.

- [ ] **Step 1: Write a read-only probe that can prove all required role/database/default-privilege predicates.**
- [ ] **Step 2: Write bootstrap to satisfy the probe, using secret files and `ON_ERROR_STOP`.**
- [ ] **Step 3: Make bootstrap reject a non-empty/non-pristine target database instead of silently repairing unknown state.**
- [ ] **Step 4: `bash -n` both scripts and review SQL for idempotency/one-shot semantics.**
- [ ] **Step 5: Commit.**

### Task R4.4: Add PgBouncer and Redis proof scripts

**Files:**
- Create: `deploy/vps/data-plane/scripts/probe-pgbouncer.sh`
- Create: `deploy/vps/data-plane/scripts/probe-redis.sh`

**PgBouncer proof must verify:**
- runtime client auth via `pgbouncer:6432`;
- server identity is `eventsales_runtime:event_sales_prod:5432`;
- runtime DML works on a disposable proof object created by migrator/bootstrap authority only;
- runtime DDL denied;
- direct PostgreSQL runtime-client auth denied;
- transaction-pool backend reuse;
- named prepared statement behavior with `max_prepared_statements=200`;
- pool settings exact; no host port.

**Redis proof must verify:**
- production prefix accepted;
- out-of-prefix write denied;
- real rate-limit command sequence works (`MULTI/EXEC`, `ZREMRANGEBYSCORE`, `ZADD`, `ZCARD`, `PEXPIRE`, optional cleanup `ZREM`);
- hot-state `SET PX`/`GET` works;
- `SCAN` bounded to production prefix works;
- unrelated dangerous/admin/write commands denied to runtime as appropriate;
- stats identity reads only allowed operational commands and cannot write;
- unauthenticated/default access denied;
- maxmemory 384 MiB, `noeviction`, persistence disabled.

- [ ] **Step 1: Write probes with bounded timeouts and secret-safe output.**
- [ ] **Step 2: Ensure failure containers/evidence are not auto-removed by invocation docs.**
- [ ] **Step 3: `bash -n` scripts.**
- [ ] **Step 4: Commit.**

### Task R4.5: Add private and ingress app Compose definitions

**Files:**
- Create: `deploy/vps/app/compose.yaml`
- Create: `deploy/vps/app/compose.ingress.yaml`
- Create: `deploy/vps/app/README.md`

**Private app Compose contract:**
- service `app` only;
- image is mandatory `EVENTSALES_IMAGE_REF` and must be digest-pinned; no `build:`;
- project run under `eventsales-app`;
- external networks named exactly `eventsales-prod_eventsales_data` and `eventsales-prod_eventsales_edge`;
- network alias `eventsales-app` on edge network;
- no host `ports:` in base Compose;
- 4 CPUs, 2 GiB, PIDs 512;
- non-root image user; read-only rootfs; `init: true`; `restart: unless-stopped`; cap drop ALL; no-new-privileges; bounded `/tmp` tmpfs with `noexec,nosuid`;
- `PHX_SERVER=true`, `PORT=4000`, `POOL_SIZE=20`, `DNS_CLUSTER_QUERY=eventsales-app`;
- webhook Redis buffer explicitly disabled and durability unaccepted;
- runtime env file contains runtime-only values;
- healthcheck uses release-process health and must be executable in the final image without adding packages.

**Ingress overlay contract:**
- adds only `127.0.0.1:4100:4000` to `app`;
- changes no image, network, secret, resource or command setting.

- [ ] **Step 1: Add base private Compose and docs.**
- [ ] **Step 2: Add the minimal ingress overlay.**
- [ ] **Step 3: Validate both Compose renderings with safe fixture env.**
- [ ] **Step 4: Commit.**

### Task R4.6: Add host-side app proof scripts

**Files:**
- Create: `deploy/vps/app/scripts/probe-private.sh`
- Create: `deploy/vps/app/scripts/probe-loopback.sh`

**Private probe:**
- assert exactly one `eventsales-app` app container;
- assert image reference/digest matches authorized input;
- inspect user/read-only/cap-drop/no-new-privileges/resource/PIDs/tmpfs/restart settings;
- assert networks exactly production data + edge;
- assert no published host ports;
- assert restart count 0;
- invoke `EventSales.Maintenance.PrivateRuntimeSmoke.run!()` through the running release RPC channel and verify exact safe PASS labels;
- inspect environment names only to prove forbidden secret variables are absent, never print values.

**Loopback probe:**
- assert only `127.0.0.1:4100` is published;
- prove `GET /health` and `GET /ready` on localhost;
- prove no `0.0.0.0:4100` or `[::]:4100` listener/publication;
- retain app restart count 0 and data-plane health.

- [ ] **Step 1: Write bounded scripts with no mutation and no secret values.**
- [ ] **Step 2: `bash -n` both scripts.**
- [ ] **Step 3: Commit.**

### Task R4.7: Add static deployment-contract CI gate

**Files:**
- Create: `scripts/check_vps_deploy_contract.sh`
- Modify: `.github/workflows/ci.yml`

**Static gate must reject:**
- `build:` in production app Compose;
- non-digest image placeholder contract;
- host ports in private app Compose;
- any data-service host port;
- missing internal data network;
- data service attached to edge network;
- missing exact PgBouncer transaction settings;
- missing Redis production namespace/required command family;
- enabled webhook degraded buffer in initial deployment;
- missing read-only/cap-drop/no-new-privileges/resource limits;
- missing `127.0.0.1:4100:4000` in ingress overlay;
- secret literals or obvious committed credentials in versioned deployment templates.

- [ ] **Step 1: Write the checker to use standard shell/Docker Compose tooling available on Ubuntu runners; do not add an unnecessary YAML library dependency.**
- [ ] **Step 2: Run it locally against valid files and at least one temporary intentionally-invalid fixture/mutation for each high-risk invariant.**
- [ ] **Step 3: Add a CI step/job.**
- [ ] **Step 4: Run `bash scripts/check_vps_deploy_contract.sh`.**
- [ ] **Step 5: Commit.**

**Slice R4 STOP:** Repository artifacts remain inert. Do not generate real production secrets or stage files on the VPS during this slice.

---

## Slice R5 — Operational Runbook and Repository Closeout

**Outcome:** Human/operator sequence is deterministic before any VPS mutation authority is granted.

### Task R5.1: Create canonical VPS production runbook

**Files:**
- Create: `docs/deployment/vps-production.md`
- Modify: `docs/deployment/runtime-config.md`
- Modify: `docs/deployment/migrations-and-release.md`
- Modify: `docs/deployment/pgbouncer.md`

**Runbook lifecycle:**

1. D1-B0 read-only host/D0 preflight.
2. D1-B1 stage versioned production data-plane bundle in a new root-only path.
3. D1-B2 fresh production secret generation.
4. D1-B3 production PostgreSQL first start/bootstrap.
5. D1-B4 PgBouncer/Redis start.
6. D1-C production data-plane probes/acceptance.
7. D1-D build/publish/approve immutable app image digest.
8. D1-E stage private app bundle/runtime env.
9. D1-F one-shot migration using direct migrator URL and approved image digest.
10. D1-G temporary private app start with bootstrap credentials.
11. D1-H explicit bootstrap invocation.
12. D1-I recreate final private app from same digest without bootstrap/direct credentials.
13. D1-J private runtime proof.
14. D1-K loopback ingress overlay and local-only proof.
15. D1-L OLS configuration staging/upstream proof.
16. D1-M public cutover.
17. D1-N final closeout/rollback evidence.

- [ ] **Step 1: Write exact preconditions/expected state/STOP conditions for every transition.**
- [ ] **Step 2: Define failure evidence preservation and authority-consumption point for every one-shot command.**
- [ ] **Step 3: Define rollback boundaries; database rollback is never automatic and requires backup/data-compatibility review.**
- [ ] **Step 4: Define final environment-secret inventory and prove temporary bootstrap/migration inputs are absent after final app recreation.**
- [ ] **Step 5: Add references to the approved D1 design and this implementation plan.**
- [ ] **Step 6: Commit.**

### Task R5.2: Whole-repository verification

- [ ] Run `mix format --check-formatted`.
- [ ] Run `mix compile --warnings-as-errors`.
- [ ] Run `mix test`.
- [ ] Run `mix credo --strict`.
- [ ] Run `mix sobelow`.
- [ ] Run `mix deps.audit` and `mix hex.audit`.
- [ ] Run `mix dialyzer` if the branch's normal PR gate requires it.
- [ ] Run `bash scripts/check_vps_deploy_contract.sh`.
- [ ] Build the production Dockerfile locally with synthetic revision metadata.
- [ ] Confirm `git diff --check`.
- [ ] Confirm changed-file scope matches D1 repository slices only.
- [ ] Confirm no generated secret file or `.env` value is tracked.
- [ ] Confirm no production mutation scripts are automatically invoked by CI.

**Repository implementation success:** all repository tests/quality/static deployment gates pass, image workflow exists but has not deployed anything, and `APP_DEPLOYMENT_AUTHORIZED=NO` remains true.

---

# 3. VPS Execution Gates — Planned, Not Authorized

These are operational gates for later chats/authorizations. Repository implementation does not consume them.

## Gate V0 — Read-only production preflight

Prove before mutation:
- D0 still exactly accepted `3/2/1`, healthy, restart-free;
- host Redis baseline unchanged;
- enough capacity remains;
- production project/stage/volume/network names absent;
- production image digest approved and locally pullable only when image staging gate arrives;
- no port `4100` listener exists;
- OLS config untouched.

**STOP:** any D0 or host baseline drift.

## Gate V1 — Stage production data-plane artifacts

Allowed mutation: copy reviewed versioned deployment bytes to a new root-only staging path. No Docker mutation, no secret generation.

**Terminal failure:** preserve stage; do not overwrite/rerun without review.

## Gate V2 — Generate fresh production secrets

Allowed mutation: create fresh production secret directory once.

Guards:
- target absent;
- root-only parent;
- no D0 secret reads/copies;
- no stdout values/hashes.

**Terminal failure:** preserve partial target; do not regenerate over it.

## Gate V3 — Start/Bootstrap production PostgreSQL

Allowed mutation: create only new `eventsales-prod` PostgreSQL/network/volume objects required by the authorized step and run one bootstrap.

Side effects: new production volume/database/roles/default privileges.

**Terminal failure:** no bootstrap rerun or DB repair until forensic review.

## Gate V4 — Start PgBouncer + Redis

Allowed mutation: start new production services only after PostgreSQL bootstrap proof.

**STOP:** any host-port publication, D0 attachment, health failure, or secret metadata drift.

## Gate V5 — Production data-plane proof

Run PostgreSQL/PgBouncer/Redis proofs once. Preserve failed probe objects; successful probes are removed only after explicit acceptance.

Success includes transaction pooling, prepared statements, runtime DML, runtime DDL denial, direct runtime-client auth denial, Redis prefix/command ACL, Redis maxmemory/policy/persistence, and D0/host Redis isolation.

## Gate V6 — Approve immutable app digest

Requires successful GHCR build, accepted source SHA, exact digest, build provenance/SBOM evidence as available, and local image dependency closure.

No app start yet.

## Gate V7 — One-shot migration

Uses same approved app image digest with migration-only env and direct PostgreSQL network path.

Guards:
- current backup/restore strategy reviewed before any destructive migration possibility;
- production data plane accepted;
- app absent;
- migration container has no public port;
- migration env contains `DIRECT_DATABASE_URL` migrator credentials and no runtime-only public bootstrap exposure.

**Terminal failure:** preserve container/output; no blind rerun or rollback.

## Gate V8 — Temporary private bootstrap app

Start app privately from approved digest with bootstrap variables only long enough to reach readiness and invoke `EventSales.Release.bootstrap()` via RPC.

No host port.

After success, bootstrap-authorized app is stopped/recreated from same digest with bootstrap variables removed.

## Gate V9 — Final private app proof

Final runtime app must have:
- no direct/migrator/bootstrap/backup secrets;
- exact 4 CPU/2 GiB/PIDs/security/network settings;
- zero restarts;
- no host port;
- `PrivateRuntimeSmoke=PASS`;
- data plane remains healthy/restart-free;
- D0 remains untouched.

## Gate V10 — Loopback ingress

Apply only ingress overlay and recreate app if required.

Success:
- exact `127.0.0.1:4100:4000` publication;
- `/health` 200;
- `/ready` 200;
- no non-loopback listener/publication;
- zero unexpected restarts.

## Gate V11 — OLS upstream staging

Separate OLS config authority.

Requirements:
- upstream points to `127.0.0.1:4100`;
- forwarded scheme/host headers support `force_ssl` and origin checks;
- WebSocket upgrade path verified for LiveView;
- configuration syntax check before reload;
- rollback captures previous config bytes/identity.

No public DNS/route switch yet unless already existing hostname routing is the exact staged authority.

## Gate V12 — Public cutover

Final public verification:
- HTTPS health/readiness/application pages;
- LiveView WebSocket;
- valid/invalid webhook behavior;
- admin auth and protected Oban UI;
- background job success/retry;
- DB via PgBouncer only;
- Redis hot/warm paths;
- no data-service ports;
- host Redis unchanged;
- app/data-plane restarts remain zero or explicitly explained;
- rollback remains available.

---

# 4. Performance & Scaling Review

## Data layer classification

| Data/work | Layer | D1 behavior |
|---|---|---|
| Active dashboard/event hot summaries | Hot | ETS/GenServer `HotStateAggregator`; Phoenix PubSub broadcasts; no request-time large scans. |
| Recoverable dashboard snapshots | Warm | Redis `eventsales:prod:*`, bounded TTL; SET/PX + bounded SCAN restore. |
| Webhook intake rate limit | Warm/high velocity | Redis sorted sets, 60s default window; atomic Redix transaction pipeline. |
| Durable sales/catalog/audit/jobs | Cold/durable | PostgreSQL through PgBouncer for runtime; direct only for migrations/admin authority. |
| Oban jobs | Durable async | PostgreSQL jobs; `Oban.Notifiers.PG` for notifications; heavy work remains async. |
| Realtime UI | Hot/realtime | Phoenix PubSub + LiveView push; no polling. |
| Analytics at future flash-sale scale | Cached/read-optimized | Existing aggregates/hot state first; read replicas/materialized views required before claiming peak analytics scale. |
| Static assets | CDN/OLS layer | Image already contains digested assets; public CDN/cache policy is later ingress optimization, not D1 data-plane logic. |

## 100k-concurrency safety assessment

D1 creates the correct horizontal-scaling boundaries but **does not certify one node for 100k concurrent users**. Before that claim:
- load test WebSocket/LiveView concurrency;
- scale app nodes horizontally;
- prove distributed Erlang/DNSCluster across nodes;
- size PgBouncer from measured DB saturation;
- introduce read replicas/materialized/cached analytics where needed;
- implement flash-sale queue/rate-limit/seat hold registry paths for the ticketing domains that require them;
- protect cache fills against stampedes and thundering herd;
- verify p99 checkout <5s and API sub-100ms targets under production-like load.

## DB call discipline

- `/ready` remains ETS-backed with one supervised DB probe every 5 seconds and 15-second stale cutoff.
- Runtime uses PgBouncer transaction pooling; initial 20 Ecto clients multiplex to <=16 backend DB connections.
- No new request-time polling is introduced.
- Oban remains async for heavy work.

## Redis structures / TTL / invalidation / PubSub

- Rate limiter: ZSET, TTL via `PEXPIRE`, invalidation by expiry/removal; no PubSub.
- Hot-state snapshots: string/value keys, TTL default 1h, overwritten by domain event recomputation; PubSub broadcast after hot-state update.
- Webhook degraded buffer: disabled; no LIST/Lua grants initially.
- Future seat inventory: must use Redis hashes/bitmaps + expiring ZSET hold registry before flash-sale ticketing scale; not silently introduced in D1.
- Future activity feeds/visitor metrics: Redis lists/HyperLogLog where domain work requires them; not part of D1.

---

# 5. Failure Modes / Concurrency / Security Review

1. **PgBouncer prepared statements fail under real app load:** stop at private smoke; preserve evidence; do not disable prepares without review.
2. **Oban PG notifier local/distributed behavior fails:** stop runtime slice; diagnose node distribution/DNSCluster; do not revert to Postgres notifier through transaction pool.
3. **Redis ACL misses a real adapter command:** probe fails; add only evidence-backed command, update static inventory/probe; never use `+@all`.
4. **Redis ACL grants too much:** negative tests must deny unrelated prefix/admin/write operations; over-permission blocks acceptance.
5. **Migration partially applies:** preserve migration container/log; inspect `schema_migrations`; no automatic rollback/rerun.
6. **Bootstrap partially succeeds:** operations are expected idempotent, but preserve state/evidence and review before rerun.
7. **App has bootstrap/direct secrets after recreation:** hard blocker; no ingress.
8. **App container restarts:** any acceptance-stage restart count >0 blocks until explained.
9. **Data-plane container restarts:** blocks app progression.
10. **D0 changes:** hard stop; D1 may not repair D0 automatically.
11. **Host Redis changes/publication collision:** hard stop.
12. **Port 4100 binds non-loopback:** hard stop; remove/rollback only under explicit authority.
13. **OLS proxy strips WebSocket/forwarded headers:** no public cutover.
14. **Cache stampede during hot-state rebuild:** existing single-flight semantics must remain; no D1 change may bypass them.
15. **Multi-node notifier split-brain/discovery gap:** multi-node deployment remains blocked until DNSCluster/distribution proof across at least two nodes.
16. **Secrets appear in logs/errors:** hard stop; rotate exposed production credential after containment, do not continue with compromised value.
17. **Image tag drifts from approved bytes:** deployment uses digest only; tag drift irrelevant but must not replace digest authority.
18. **CI deploys automatically:** forbidden in D1; CI may build/publish artifact but no VPS mutation.

---

# 6. Scaffolding TOON Prompt

| Field | Content |
|---|---|
| Task | Implement the approved EventSales D1 repository productionization plan on an isolated branch/worktree, stopping before any VPS mutation. |
| Objective | Make EventSales repository artifacts compatible with the accepted D1 architecture: PgBouncer transaction pooling, `Oban.Notifiers.PG`, separate migration/bootstrap lifecycle, immutable GHCR image, production data-plane/app Compose definitions, private/loopback probes, and deterministic runbook gates. |
| Output | Repository-only changes listed in `docs/superpowers/plans/2026-10-20-d1-vps-production-implementation.md`; tests and CI gates pass; no real production secrets, Docker/VPS mutations, image deployment, OLS changes, or public cutover. |
| Note | Base only on accepted `main` plus the approved D1 spec/plan. Use TDD, minimal code, established patterns, signed commits, and one reviewable slice at a time. D0 is frozen. Transaction pooling is mandatory; do not substitute session pooling or `prepare: :unnamed` without failure evidence. Runtime DB uses PgBouncer; migrations direct PostgreSQL. Production Redis prefix is `eventsales:prod:*`, webhook buffer disabled. Indexes: no schema/index changes in repository productionization unless a real migration proof exposes a missing critical index; if so STOP for separate authority. Cache: retain ETS hot state and Redis warm state; snapshot TTL default 1h; rate-limit TTL 60s default. Redis structures: ZSET for webhook rate limits, string/value snapshots; LIST/Lua buffer disabled. Invalidation: existing domain events/TTL only. PubSub: existing Phoenix PubSub updates remain push-based; no polling. STOP immediately on scope drift, secret exposure, D0 mutation, unreviewed dependency addition, or failed test that implies architecture change. |

---

# 7. Granular TOON Micro-Prompts

## Config / Runtime

### TOON D1-R1 — Oban notifier switch

| Field | Content |
|---|---|
| Task | Change EventSales Oban notifier authority from `Oban.Notifiers.Postgres` to `Oban.Notifiers.PG` and update its focused tests/docs. |
| Objective | Remove PostgreSQL `LISTEN/NOTIFY` session dependence so runtime can use PgBouncer transaction pooling. |
| Output | Modified `config/config.exs`, `test/event_sales/oban_topology_test.exs`, `docs/architecture/oban-pgbouncer.md`, `docs/architecture/db-topology.md`, `docs/deployment/pgbouncer.md`; targeted tests pass. |
| Note | Change notifier only; preserve queues, engine, peer/leadership and job durability. Do not introduce polling notifier or session pooling. Indexes: none. Cache/TTL: unchanged. Redis: unchanged. Invalidation: unchanged. PubSub: Oban notifier moves to Erlang `:pg`; Phoenix PubSub remains unchanged. STOP if PG notifier cannot start in tests; diagnose before architecture changes. |

### TOON D1-R2 — Production pool and release distribution

| Field | Content |
|---|---|
| Task | Set production Repo default `POOL_SIZE=20` and add `rel/env.sh.eex` for unique distributed release node identity using externally supplied cookie. |
| Objective | Align one-node production runtime with PgBouncer sizing and establish the cluster boundary required by `Oban.Notifiers.PG` and future horizontal scaling. |
| Output | Modified `config/runtime.exs`, created `rel/env.sh.eex`, created/updated focused runtime contract test, updated runtime docs. |
| Note | Do not embed/generate/print release cookie. Node name must derive from container hostname, not be globally fixed. DNSCluster query comes from deployment as `eventsales-app`. Indexes: none. Cache/TTL/Redis: unchanged. Invalidation: unchanged. PubSub: existing Phoenix PubSub must remain. STOP on fixed-node collision risk or secret-in-repo design. |

## Release Lifecycle

### TOON D1-R3 — Separate bootstrap release primitive

| Field | Content |
|---|---|
| Task | Add `EventSales.Release.bootstrap/1` as a separate bootstrap entrypoint while preserving `migrate/1` and Railway compatibility. |
| Objective | Make VPS migration and first-production bootstrap separately authorized transitions; normal app startup must run neither. |
| Output | Modified `lib/event_sales/release.ex`, `test/event_sales/release_test.exs`, deployment docs; `bootstrap/1` tested for ordering/failure/redaction. |
| Note | Reuse existing AdminBootstrap/SourceSystemBootstrap; do not duplicate domain logic or change idempotency semantics. Indexes: migrations remain schema authority; no new index. Cache/TTL/Redis/PubSub: N/A. STOP if separation requires changing bootstrap domain behavior. |

## Private Proof

### TOON D1-R4 — Private runtime smoke module

| Field | Content |
|---|---|
| Task | Create `EventSales.Maintenance.PrivateRuntimeSmoke` and its unit tests for bounded, secret-safe pre-ingress production verification. |
| Objective | Prove the actual private runtime uses PgBouncer transaction pooling, prepared Ecto/Ash queries, Oban PG notifier/jobs, Redis rate-limit/snapshot paths and ETS readiness before any host port exists. |
| Output | `lib/event_sales/maintenance/private_runtime_smoke.ex`, `test/event_sales/maintenance/private_runtime_smoke_test.exs`; safe PASS/failure contract. |
| Note | Reuse real adapters/workers; no fake integration success in production path. No public HTTP dependency. Indexes: existing migration indexes only; smoke may detect query failure but must not mutate schema. Cache: ETS readiness and hot state; Redis snapshot TTL 1h. Redis: ZSET rate limiter plus SET/GET snapshot. Invalidation: existing TTL/domain-event paths. PubSub: preserve existing broadcasts; no polling. STOP on secret-bearing output or direct runtime PostgreSQL requirement. |

## Image / CI

### TOON D1-R5 — Immutable Docker image metadata

| Field | Content |
|---|---|
| Task | Harden `Dockerfile` for immutable production artifact metadata while preserving non-root release-only runtime. |
| Objective | Ensure one reviewed source commit maps to an inspectable image artifact without baking deployment secrets or requiring production source builds. |
| Output | Modified `Dockerfile` (and production tzdata config if required); local build/inspect evidence passes. |
| Note | Keep Elixir/OTP versions aligned with `mix.exs`; no runtime package bloat unless demonstrated. Indexes/Cache/Redis/Invalidation/PubSub: no behavioral changes. STOP if image needs secrets at build time. |

### TOON D1-R6 — GHCR image workflow

| Field | Content |
|---|---|
| Task | Add `.github/workflows/event-sales-image.yml` to build/test/push EventSales image and report immutable digest/provenance. |
| Objective | Replace VPS source builds with registry-hosted immutable artifacts. |
| Output | Workflow publishes `ghcr.io/jcschoeman96/eventsales`, emits digest, and never deploys. |
| Note | Minimal permissions; do not publish from untrusted PRs; digest, not tag, is deployment authority. Indexes/Cache/TTL/Redis/Invalidation/PubSub: N/A. STOP if workflow requires production secrets or contains VPS mutation. |

## Data Plane

### TOON D1-R7 — Production data-plane Compose

| Field | Content |
|---|---|
| Task | Create `deploy/vps/data-plane/compose.yaml` and structural templates/docs for the new `eventsales-prod` PostgreSQL/PgBouncer/Redis stack. |
| Objective | Version the exact production infrastructure contract without touching D0 or the VPS. |
| Output | Production Compose, PgBouncer template, Redis ACL template, README; `docker compose config` passes with safe fixtures. |
| Note | Exact pinned images; DB 2CPU/3GiB; PgBouncer transaction mode 64 clients, 12+4 pool, 16 backend, prepared=200; Redis 0.5CPU/512MiB, maxmemory 384MiB noeviction persistence off; no data-service ports. Indexes: DB schema indexes remain app migrations. Cache: Redis warm, PostgreSQL cold. TTL: app-owned. Redis: runtime prefix `eventsales:prod:*`; ZSET + snapshot commands only. Invalidation: TTL/domain events. PubSub: none at infra layer. STOP on D0 references or public data ports. |

### TOON D1-R8 — Fresh secret generation/rendering

| Field | Content |
|---|---|
| Task | Create root-only secret generation/rendering scripts for production Pg/Postgres/PgBouncer/Redis files, with dry-run metadata verification. |
| Objective | Guarantee production credentials are fresh, correctly permissioned and never copied from D0 or printed. |
| Output | `generate-secrets.sh`, `render-runtime-config.sh`, dry-run verification. |
| Note | Fail if target exists/symlink; umask 077; no value/hash stdout. Indexes/Cache/TTL/Redis/Invalidation/PubSub: N/A except rendered ACL must use production prefix and approved command family. STOP on any D0 secret access or stdout secret exposure. |

### TOON D1-R9 — PostgreSQL bootstrap/probe scripts

| Field | Content |
|---|---|
| Task | Create one-shot production PostgreSQL bootstrap and read-only probe scripts for `event_sales_prod` and migrator/runtime/backup roles/default privileges. |
| Objective | Establish least-privilege production DB ownership before migrations without using the disposable proof DB. |
| Output | `bootstrap-postgres.sh`, `probe-postgres.sh`; shell syntax and SQL review pass. |
| Note | Connection limits migrator=2/runtime=20/backup=2; runtime no DDL ownership; default privileges for tables/sequences/functions; revoke unintended PUBLIC create. Indexes: none created here; migrations own indexes. Cache/TTL/Redis/PubSub: N/A. STOP on non-pristine target DB or bootstrap partial failure; no blind rerun. |

### TOON D1-R10 — PgBouncer/Redis proof scripts

| Field | Content |
|---|---|
| Task | Create bounded secret-safe PgBouncer and Redis production proof scripts. |
| Objective | Prove transaction pooling/prepared statements/runtime privilege boundaries and exact Redis ACL behavior before app deployment. |
| Output | `probe-pgbouncer.sh`, `probe-redis.sh`; `bash -n` passes; README documents forensic preservation. |
| Note | PgBouncer: prepared=200, runtime DML yes, DDL no, direct client auth no. Redis: ZSET transaction commands, SET/GET PX, bounded SCAN, prefix isolation, stats read-only, default denied, maxmemory/noeviction/persistence exact. Indexes: proof uses bounded disposable proof table/object only under migrator authority. Cache TTL: rate-limit 60s default, snapshot 1h app default. PubSub: N/A. STOP on first failure; no rerun. |

## App Compose / Probes

### TOON D1-R11 — Private app Compose + ingress overlay

| Field | Content |
|---|---|
| Task | Create private `eventsales-app` Compose and a separate ingress overlay that adds only `127.0.0.1:4100:4000`. |
| Objective | Keep application runtime proof isolated from host/public ingress and prevent Compose from recreating production data services. |
| Output | `deploy/vps/app/compose.yaml`, `compose.ingress.yaml`, README; rendered Compose contract passes. |
| Note | Digest image only, no build; 4CPU/2GiB/PIDs512; read-only, cap-drop ALL, NNP, `/tmp` noexec/nosuid, restart unless-stopped; external prod data+edge networks, alias `eventsales-app`; base has zero ports. Indexes: N/A. Cache: app uses existing ETS/Redis. TTL/Redis/invalidation/PubSub: preserve approved runtime architecture. STOP if private compose publishes a port or contains direct/migrator secrets. |

### TOON D1-R12 — Private/loopback host probes

| Field | Content |
|---|---|
| Task | Create host-side scripts that prove private app security/runtime and later loopback-only HTTP ingress. |
| Objective | Make app acceptance evidence deterministic without exposing secret values or collapsing lifecycle gates. |
| Output | `probe-private.sh`, `probe-loopback.sh`; shell syntax passes. |
| Note | Private probe calls `PrivateRuntimeSmoke` and proves no host port/forbidden env names; loopback proves only 127.0.0.1:4100 plus `/health` and `/ready`. Indexes: N/A. Cache/readiness: `/ready` must remain ETS-backed. Redis/PubSub: private smoke proves real adapters and Oban notifier. STOP on restart count >0, non-loopback bind, or secret-variable boundary breach. |

## CI / Docs

### TOON D1-R13 — Static VPS deployment contract gate

| Field | Content |
|---|---|
| Task | Add `scripts/check_vps_deploy_contract.sh` and CI invocation to reject production deployment contract drift. |
| Objective | Catch dangerous Compose/security/pooling/ACL/ingress regressions before merge. |
| Output | Checker + `.github/workflows/ci.yml` update; valid contract passes and intentionally invalid fixtures fail. |
| Note | Use existing runner tooling; avoid new YAML dependency unless unavoidable. Indexes: checker ensures no unplanned schema migration scope. Cache/TTL/Redis: pin approved namespace/structures/settings. Invalidation/PubSub: verify no polling architecture introduced by deployment config. STOP if checker relies on production secrets or network access. |

### TOON D1-R14 — Canonical VPS runbook

| Field | Content |
|---|---|
| Task | Write `docs/deployment/vps-production.md` with exact D1-B through D1-N state transitions, guards, side effects, authority consumption points, evidence and STOP rules. |
| Objective | Ensure operators/agents cannot skip from repository readiness to public deployment or silently rerun failed one-shot operations. |
| Output | Canonical runbook cross-linked to spec/plan and updated runtime/migration/PgBouncer docs. |
| Note | Must preserve D0, separate migration/bootstrap/final runtime recreation/private proof/loopback/OLS/public cutover. Indexes: migrations own; backup review before destructive rollback. Cache/TTL/Redis/invalidation/PubSub: document approved production values/structures and no-polling rule. STOP if any step combines independent mutation authorities. |

## Repository Closeout

### TOON D1-R15 — Whole-branch verification

| Field | Content |
|---|---|
| Task | Run the complete EventSales repository quality, deployment-contract, Docker-build and changed-scope verification before requesting merge. |
| Objective | Make the repository branch merge-ready without performing any production mutation. |
| Output | Fresh evidence for format/compile/tests/Credo/Sobelow/audits/Dialyzer as required, deployment checker, Docker build/inspect, `git diff --check`, changed-file scope, no tracked secrets. |
| Note | Do not waive failures. Indexes: no unexplained migration/index diff. Cache/TTL/Redis/PubSub: all approved contracts must remain represented. STOP on any failure, unsigned history if repository requires signed commits, unexpected generated migration/resource snapshot diff, secret file, or VPS mutation. |

---

# 8. Success Criteria Before Any VPS Mutation

Repository work is complete only when all are true:

```text
D1_SPEC=APPROVED
D1_REPOSITORY_PLAN=IMPLEMENTED_AND_REVIEWED
D0=UNCHANGED
OBAN_NOTIFIER=Oban.Notifiers.PG
PGBOUNCER_RUNTIME_MODE=transaction
PROD_REPO_POOL_SIZE_DEFAULT=20
DISTRIBUTED_RELEASE_NODE=CONFIGURED
RELEASE_COOKIE=EXTERNAL_SECRET
MIGRATION_ENTRYPOINT=SEPARATE
BOOTSTRAP_ENTRYPOINT=SEPARATE
PRIVATE_RUNTIME_SMOKE=IMPLEMENTED
PROD_DATA_PLANE_COMPOSE=VERSIONED
PROD_APP_PRIVATE_COMPOSE=VERSIONED
INGRESS_OVERLAY=LOOPBACK_ONLY
PRODUCTION_IMAGE_WORKFLOW=GHCR_DIGEST
VPS_DEPLOYMENT_CONTRACT_CI=PASS
TRACKED_PRODUCTION_SECRETS=0
APP_DEPLOYMENT_AUTHORIZED=NO
OLS_CHANGE_AUTHORIZED=NO
```

# 9. Final STOP Conditions

During repository implementation, stop and return for review if any of the following occurs:

- accepted `main` moves and the branch has not been rebased/re-reviewed;
- D0 files/runtime must be mutated to make D1 work;
- transaction pooling appears incompatible with a real required runtime behavior;
- `Oban.Notifiers.PG` requires an architecture/dependency change beyond the approved design;
- Redis requires a command outside the static inventory and real adapter evidence does not justify it;
- a schema/index migration appears necessary outside previously accepted application migrations;
- secret material is printed, committed, hashed into evidence, or required at image build time;
- a production Compose service needs a host port before its authorized ingress phase;
- CI/image workflow would mutate the VPS or public route;
- tests/quality gates fail;
- branch history/signatures do not meet repository merge requirements.

**No VPS mutation is authorized by this plan.**
