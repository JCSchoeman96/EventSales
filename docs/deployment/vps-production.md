# EventSales D1 VPS production runbook

This document defines a future operating procedure. It grants no execution authority. A merge, commit, image publication, or completed earlier gate does not authorize the next gate. Every transition requires a separate, explicit owner authorization after its preflight evidence is reviewed.

R5 is documentation and repository verification only. No production image or node is selected here. `D1_PRODUCTION=ACCEPTED` remains false until the owner explicitly accepts the completed V12 and closeout evidence.

## Authority and locked decisions

Resolve evidence in this order:

1. Current accepted repository evidence at the reviewed commit and tree.
2. `R1-RULING-01` in [`2026-10-21-d1-vps-production-cluster-node-ruling.md`](../superpowers/specs/2026-10-21-d1-vps-production-cluster-node-ruling.md).
3. The approved [D1 architecture](../superpowers/specs/2026-10-20-d1-vps-production-architecture-design.md).
4. The approved [D1 implementation plan](../superpowers/plans/2026-10-20-d1-vps-production-implementation.md).
5. Accepted R3/R4 repository decisions and artifacts.
6. This runbook.
7. Operator reports.

If evidence at the applicable authority level cannot resolve a disagreement, stop with `STOP=AUTHORITY_CONFLICT`. Preserve the conflicting non-secret evidence and request a new decision. Do not resolve a conflict by relying on an operator report.

`R1-RULING-01` locks the production release identity and discovery boundary:

```text
RELEASE_DISTRIBUTION=name
RELEASE_NODE=event_sales@EVENTSALES_NODE_IP
CLUSTER_DNS_QUERY=eventsales-app
CLUSTER_NETWORK=eventsales-prod_eventsales_data
EDGE_NETWORK_CLUSTER_ALIAS=FORBIDDEN
```

The ruling names this setting `CLUSTER_DNS_QUERY`; the current Compose/runtime environment binding is `DNS_CLUSTER_QUERY=eventsales-app`. The `eventsales-app` alias belongs only to `eventsales-prod_eventsales_data`. Never derive the node identity from Docker `HOSTNAME`, place the alias on the edge network, or invent an IP or DNS suffix. Select `EVENTSALES_NODE_IP` only after the read-only network collision audit proves a candidate is safe. Its value must equal the app's `ipv4_address` on the data network.

Keep these identities distinct in every review and evidence record:

- Repository working-tree bytes.
- Reviewed commit SHA and tree SHA.
- Root-owned staged bytes whose identity matches that commit and tree.
- The separately reviewed narrow root wrapper and the immutable bytes it executes.
- The running container and its runtime state.

The approved architecture names `/root/eventsales-prod/` as the production authority root. R5 does not select a child staging path, secret path, wrapper path, or OpenLiteSpeed configuration path. A later authority must identify each required path from an accepted source. The wrapper is not implemented by this runbook. If a privileged transition lacks a separately reviewed wrapper that executes reviewed, root-owned immutable staged bytes, stop with `STOP=ROOT_WRAPPER_NOT_REVIEWED`.

`agentops` is an unprivileged SSH operator. Root SSH is not the normal path. `agentops` must not belong to the Docker group and must not receive broad `NOPASSWD` sudo, `sudo -i`, or `sudo bash`. Never invoke privilege from an `agentops`-writable checkout. Do not copy an operator checkout to root and execute it.

The state sequence is:

```text
REPOSITORY_ACCEPTED
  -> PREFLIGHT_ACCEPTED
  -> DATA_PLANE_STAGED
  -> SECRETS_GENERATED
  -> POSTGRES_BOOTSTRAPPED
  -> DATA_PLANE_RUNNING
  -> DATA_PLANE_ACCEPTED
  -> IMAGE_APPROVED
  -> APP_STAGED
  -> MIGRATED
  -> BOOTSTRAP_APP_RUNNING
  -> BOOTSTRAPPED
  -> FINAL_PRIVATE_RUNNING
  -> PRIVATE_ACCEPTED
  -> LOOPBACK_ACCEPTED
  -> OLS_STAGED
  -> PUBLIC_ACCEPTED
  -> CLOSED
```

Every failed transition enters `BLOCKED_<TRANSITION>` and makes that authorization terminal. Do not automatically retry, repair, clean up, or roll back. Preserve non-secret output and resulting state. Any further action requires a new review and a new explicit authorization. Specific terminal states below, including `BLOCKED_SECRET_GENERATION` and `BLOCKED_BOOTSTRAP`, apply as written.

## Governance prerequisite for V0

The repository has `scripts/check_vps_deploy_contract.sh` and CI runs the `vps_deploy_contract` job. That job is not currently a required Protect-main check. A separate, reviewed GitHub governance change and readback must make `vps_deploy_contract` required before V0. Exclude `wordpress_plugin_distribution` from that required-check decision. Do not mutate a ruleset as part of R5 or this runbook.

Until that change is separately reviewed and read back:

```text
GOVERNANCE_HARDENING_PENDING=YES
RULESET_HARDENING_REQUIRED_BEFORE_V0=YES
RULESET_MUTATED=NO
V0_EXECUTION_AUTHORIZED=NO
```

## Transition record

Each gate below records its entering state, prior acceptance, authority, read-only preflight, source inputs, permitted and forbidden actions, exact authority-consumption point, side effects, success evidence, STOP conditions, failure evidence, rerun rule, rollback boundary, resulting state, and the next gate that remains unauthorized.

### B0 / V0: read-only production preflight

- **Entering state:** `REPOSITORY_ACCEPTED`.
- **Prior acceptance:** Confirm the reviewed repository SHA and tree still match the accepted source. Complete the governance prerequisite above, including independent readback that `vps_deploy_contract` is required.
- **Authority:** A separate, explicit, read-only V0 authorization is required. It covers only the bounded inventory and health reads in this gate.
- **Read-only preflight and inputs:** Use the accepted D0 closeout record, the approved repository commit/tree, current host inventory, and the accepted network-collision audit method. Prove D0 is exactly three containers, two project networks, and one project volume; all three containers are healthy with zero restarts. Compare the host Redis baseline with its accepted record. Confirm that projects `eventsales-prod` and `eventsales-app`, networks `eventsales-prod_eventsales_data` and `eventsales-prod_eventsales_edge`, and volume `eventsales-prod_postgres_data` are absent; port 4100 has no listener; OpenLiteSpeed bytes and routing remain untouched; available CPU, memory, and storage can meet the approved envelopes (PostgreSQL 2 CPU/3 GiB, PgBouncer 0.5 CPU/128 MiB, Redis 0.5 CPU/512 MiB, and app 4 CPU/2 GiB/512 PIDs); and the Docker network collision audit is complete. Do not select `EVENTSALES_NODE_IP` until the audit proves a candidate safe. V0 records the audit result without selecting an address.
- **Source inputs:** Accepted commit/tree identity; D0 inventory and health evidence; host Redis baseline; accepted production names from the Compose files; host capacity evidence; network audit output; governance readback. Do not infer missing identities or thresholds.
- **Permitted / forbidden:** Read-only inspection only. Do not repair drift, restart or create objects, read secrets, change GitHub rulesets, select the node IP, connect to production WordPress, or touch OpenLiteSpeed.
- **Authority consumption / side effects:** V0 authority is consumed by the first host inventory read. The transition must cause no host, Docker, database, Redis, WordPress, OLS, GitHub governance, or application side effect.
- **Success evidence / resulting state:** Record SHA/tree identity, D0 counts and health/restart state, host Redis baseline comparison, expected production-object absence, port 4100 absence, OLS identity, capacity result, network-collision audit result, and governance readback. Store only through an evidence destination separately approved for the later operation. Result: `PREFLIGHT_ACCEPTED`.
- **STOP / failure evidence:** Governance still pending means `STOP=GOVERNANCE_HARDENING_PENDING` before V0 starts. A started V0 that fails enters `BLOCKED_B0`. D0 drift means `STOP=D0_BASELINE_DRIFT`. Any expected production object already present means `STOP=UNEXPECTED_PREEXISTING_PRODUCTION_OBJECT`. Stop for changed SHA/tree, host Redis drift, port 4100 listener, OLS drift, insufficient capacity, incomplete collision audit, or an unresolved candidate. Preserve the bounded non-secret read output. Never repair during V0.
- **Rerun / rollback / next gate:** A failed V0 authorization is terminal; new review and authorization are required. There is no rollback for read-only inspection. B1/V1 remains unauthorized.

### B1 / V1: stage the data-plane bundle

- **Entering state:** `PREFLIGHT_ACCEPTED`.
- **Prior acceptance:** V0 evidence and governance readback are accepted; the reviewed source SHA/tree are unchanged.
- **Authority:** A separate, explicit V1 authorization permits staging reviewed data-plane repository bytes only.
- **Read-only preflight and inputs:** Confirm the target is absent, the accepted SHA/tree are exact, the approved root and target ownership rules are known, no symlink is in the path, and `agentops` cannot write the target. Inputs are only the accepted `deploy/vps/data-plane` Compose file, README, templates, provisioner, secret generation/render scripts, PostgreSQL bootstrap/probe scripts, and PgBouncer/Redis probes.
- **Permitted / forbidden:** Copy only the reviewed bundle to a new root-owned immutable path and prove byte identity against the accepted commit/tree. Do not generate or render secrets, invoke Docker, alter D0, or stage app files.
- **Authority consumption / side effects:** V1 is consumed at the first staged-byte write. The only side effect is a new immutable data-plane bundle.
- **Success evidence / resulting state:** Record the source SHA/tree, staged-file inventory and byte-identity proof, target-absent precondition, root ownership, immutability, and absence of agentops write access. Result: `DATA_PLANE_STAGED`.
- **STOP / failure evidence:** A started transition that fails enters `BLOCKED_B1`. Stop if the target exists, is writable by agentops, contains a symlink, differs byte-for-byte, or requires unreviewed files. Preserve partial stage metadata and non-secret diagnostics.
- **Rerun / rollback / next gate:** A partial stage is preserved. Never overwrite it blindly. A new target requires review and new authorization. Removing a partial or accepted stage is a separate action, not an automatic rollback. B2/V2 remains unauthorized.

### B2 / V2: generate and render fresh secrets

- **Entering state:** `DATA_PLANE_STAGED`.
- **Prior acceptance:** V1 staging is byte-verified and accepted. The generator and renderer are the exact reviewed staged bytes.
- **Authority:** Separate explicit V2 authority is required for raw generation and for rendering. Each is one-shot; neither can authorize the other implicitly.
- **Read-only preflight and inputs:** Inspect the accepted `generate-secrets.sh` and `render-runtime-config.sh`. The raw filenames are `postgres_bootstrap_password`, `eventsales_migrator_password`, `eventsales_runtime_server_password`, `eventsales_runtime_client_password`, `eventsales_backup_password`, `redis_runtime_password`, and `redis_stats_password`. The renderer creates `pgbouncer.ini`, `pgbouncer_users.txt`, and `redis-users.acl`. Confirm the canonical absolute target is absent, its parent is root-owned and safe, no component is a symlink, and the root wrapper is reviewed. Do not read or copy any D0 secret.
- **Permitted / forbidden:** Generate fresh values only with the accepted staged scripts through the reviewed wrapper. Render only the three accepted output files from those fresh inputs. Do not print values, verifiers, or hashes; do not copy D0 credentials; do not use an agentops checkout; do not hand-edit generated files.
- **Authority consumption / side effects:** Generation authority is consumed when the generator is invoked against the absent target. Rendering authority is consumed when the renderer is invoked against the accepted generated inputs. Side effects are creation of the protected secret directory, seven raw files, and three rendered files with the ownership and modes required by the staged scripts.
- **Success evidence / resulting state:** Record filenames, counts, ownership, modes, byte lengths, uniqueness result, placeholder absence, and successful script status only. Never record values or hashes. Result: `SECRETS_GENERATED`.
- **STOP / failure evidence:** A partial generation or render enters `BLOCKED_SECRET_GENERATION`. Preserve the partial directory and non-secret metadata. Stop for any existing target/file, unsafe parent, symlink, permission mismatch, duplicate value, placeholder, output leakage, missing wrapper, or unexpected file. Never regenerate over partial state.
- **Rerun / rollback / next gate:** No retry, replacement, or deletion under the consumed authorization. A new secret set requires forensic review and fresh explicit authority. Secret removal or rotation is not an automatic rollback. B3/V3 remains unauthorized.

### B3 / V3: provision networks and bootstrap PostgreSQL

- **Entering state:** `SECRETS_GENERATED`.
- **Prior acceptance:** V2 generation and rendering passed; V0 D0 and host Redis baselines remain accepted; the secret metadata and staged bundle are verified.
- **Authority:** A separate, explicit V3 authorization must enumerate the network, first-volume, PostgreSQL-start, and one-shot bootstrap actions. Privileged execution requires the reviewed root wrapper and root-owned staged bytes.
- **Read-only preflight and inputs:** Recheck the exact production network names and absence, network driver/internal settings, secret filenames and metadata without reading values, Compose project identity `eventsales-prod`, and volume state. The only valid first-provision volume state is `INITIAL_ABSENT`. `EXPECTED_PRESENT` is valid only for a later separately authorized lifecycle. `UNEXPECTED_PREEXISTING_BEFORE_FIRST_PROVISION` is a STOP. `DELETION_REQUIRES_SEPARATE_AUTHORITY` always applies.
- **Permitted / forbidden:** Provision the data network before the edge network using the accepted provisioner; the data network is bridge/internal and the edge network is bridge/non-internal. Confirm the initially absent volume, then start only PostgreSQL within its approved 2 CPU/3 GiB envelope and run the accepted one-shot bootstrap. The database is `event_sales_prod`, owned by `eventsales_migrator`; roles are exactly `eventsales_migrator`, `eventsales_runtime`, and `eventsales_backup`, with accepted connection limits 2, 20, and 2 respectively and least-privilege defaults. Run the structural PostgreSQL proof only under its explicit authority. Do not mutate D0. Never run `docker compose down -v`, `docker compose down --volumes`, `docker volume rm eventsales-prod_postgres_data`, or `docker volume prune` against production.
- **Authority consumption / side effects:** Each separately authorized network creation, initial volume creation/attachment, PostgreSQL start, bootstrap invocation, and structural probe consumes its own bounded grant at the first mutation or probe operation. Side effects are the two production networks, the new PostgreSQL container and volume, database, roles, and grants. No D0 object may change.
- **Success evidence / resulting state:** Prove both network identities/settings; volume identity and `EXPECTED_PRESENT` after first creation; PostgreSQL healthy and restart-free; database owner; exact role names/limits; runtime has no DDL ownership; backup read privileges; default privileges and no unintended PUBLIC access. Record identities and structural results only. Result: `POSTGRES_BOOTSTRAPPED`.
- **STOP / failure evidence:** Stop on a pre-existing volume/network/object, network mismatch, unhealthy service, any restart, bootstrap partial failure, unexpected role/database state, D0 drift, or secret metadata drift. Preserve container, volume, bootstrap output, and probe evidence. Never rerun bootstrap without forensic review.
- **Rerun / rollback / next gate:** A failed action enters `BLOCKED_B3`; preserve all created state. No automatic repair, bootstrap retry, volume deletion, or rollback. Any database rollback requires separate backup, compatibility, and destructive-action review. B4/V4 remains unauthorized.

### B4 / V4: start PgBouncer and Redis

- **Entering state:** `POSTGRES_BOOTSTRAPPED`.
- **Prior acceptance:** PostgreSQL structural proof is accepted; PostgreSQL, production networks, volume, secrets, D0, and host Redis match their accepted evidence.
- **Authority:** A separate V4 authorization permits only the PgBouncer and Redis lifecycle. Use the reviewed root wrapper and staged bytes.
- **Read-only preflight and inputs:** Confirm PostgreSQL health and zero restarts, rendered configuration metadata, exact service images/settings from the accepted data-plane Compose, both production networks, and no app or data-service host-port configuration.
- **Permitted / forbidden:** Start PgBouncer within its approved 0.5 CPU/128 MiB envelope and in transaction mode with `max_client_conn=64`, `default_pool_size=12`, `reserve_pool_size=4`, `max_db_connections=16`, `max_user_connections=16`, and `max_prepared_statements=200`. Start Redis within its approved 0.5 CPU/512 MiB container envelope, with 384 MiB maxmemory, `noeviction`, persistence disabled, and runtime namespace `eventsales:prod:*`. Keep all data services on the internal data network only. No host ports, app attachment, or edge-network attachment are allowed here.
- **Authority consumption / side effects:** V4 is consumed at the first service start. Side effects are the PgBouncer and Redis containers and their runtime state. Any restart during acceptance blocks progression.
- **Success evidence / resulting state:** Record exact service identities, image digests, healthy status, zero restarts, pool/ACL/config identities, resource envelopes, data-network-only membership, and no published ports. Result: `DATA_PLANE_RUNNING`.
- **STOP / failure evidence:** A started transition that fails enters `BLOCKED_B4`. Stop for any host port, edge attachment, D0 attachment, secret metadata drift, health failure, restart, or config mismatch. Preserve logs and container state; redact credentials.
- **Rerun / rollback / next gate:** No restart, recreate, or repair under the consumed authority. A new review and authorization are required. Removing services or changing the volume is not automatic rollback. C/V5 remains unauthorized.

### C / V5: prove and accept the data plane

- **Entering state:** `DATA_PLANE_RUNNING`.
- **Prior acceptance:** V4 services are healthy and restart-free; PostgreSQL structural proof, D0, and host Redis baseline remain accepted.
- **Authority:** A separate, one-shot V5 proof authorization covers the accepted probes. The reviewed root wrapper and staged probe bytes are required.
- **Read-only preflight and inputs:** Confirm exact probe identities and versions, root-only secret directory metadata, data-plane container identities, no host ports, and accepted D0 baseline. Use `probe-postgres.sh`, `probe-pgbouncer.sh`, and `probe-redis.sh`; do not reproduce their proof logic in ad hoc commands.
- **Permitted / forbidden:** Prove PostgreSQL role/privilege structure; PgBouncer runtime auth and server identity, runtime DML, DDL denial, direct runtime-client PostgreSQL auth denial, transaction backend reuse, and named prepared-statement protocol; Redis production-prefix allow and out-of-prefix denial, required command family, ZSET transaction and expiry, hot-state SET/GET, bounded SCAN, runtime/admin/dangerous-command denial, stats identity, default PING-only identity, memory/policy, and disabled persistence. Compare host Redis and D0 before and after. These probes create bounded proof objects/keys; preserve them. Do not clean them up automatically.
- **Authority consumption / side effects:** V5 authority is consumed at the first probe invocation. Side effects are only the accepted probe's bounded PostgreSQL proof table and Redis keys with their defined expiries. No service start, restart, or D0 mutation is permitted.
- **Success evidence / resulting state:** Preserve each accepted probe's safe PASS evidence and confirm no data-plane or D0 restart, host Redis change, or host-port publication. Result: `DATA_PLANE_ACCEPTED`.
- **STOP / failure evidence:** Stop at the first failed probe. Preserve the evidence file, failed check, PostgreSQL proof objects, Redis state, service IDs, and restart counts. Never rerun a failed or completed probe without new forensic review and authority.
- **Rerun / rollback / next gate:** Failed proof enters `BLOCKED_C`; no blind rerun or cleanup. Probe artifacts are not an automatic rollback target. D/V6 remains unauthorized.

### D / V6: approve an immutable application image

- **Entering state:** `DATA_PLANE_ACCEPTED`.
- **Prior acceptance:** V5 proof is accepted; the exact source commit and tree are accepted; no data-plane, D0, or host Redis drift exists.
- **Authority:** A separate V6 authorization is required to approve one published image digest. R5 selects no image and authorizes no application start.
- **Read-only preflight and inputs:** Verify the accepted source SHA/tree, successful GitHub image-workflow run and GHCR publication, image source/revision/digest metadata, dependency closure, and provenance/SBOM when available. The only acceptable reference shape is `ghcr.io/jcschoeman96/eventsales@sha256:<64 lowercase hex characters>`. A mutable tag is never deployment authority.
- **Permitted / forbidden:** Inspect the published artifact and record the exact digest under the V6 decision. Do not start or create an app, migration, bootstrap process, or ingress. Do not substitute a local verification tag or build source on the VPS.
- **Authority consumption / side effects:** V6 is consumed when the owner approves the exact digest and source linkage. The side effect is the durable image-approval record; no production container changes.
- **Success evidence / resulting state:** Record accepted source SHA/tree, GHCR workflow success, exact digest, source/digest metadata, dependency closure, and provenance/SBOM availability. Result: `IMAGE_APPROVED`.
- **STOP / failure evidence:** A started transition that fails enters `BLOCKED_D`. Stop for missing or failed publication, digest mismatch, mutable-tag reliance, missing source linkage, dependency uncertainty, or a provenance issue that the approval requires. Preserve workflow and metadata evidence without secret values.
- **Rerun / rollback / next gate:** A rejected digest stays rejected. A different image requires a new review and V6 authorization. No app rollback applies before an app exists. E remains unauthorized.

### E: stage the app bundle and protected runtime environment

- **Entering state:** `IMAGE_APPROVED`.
- **Prior acceptance:** V6 records one accepted immutable digest and source commit/tree. The safe node candidate was proven by V0's network audit; a node address is selected only under a separate reviewed decision.
- **Authority:** A separate E authorization permits staging the reviewed app Compose, ingress overlay, and protected runtime environment for later gates. E has no V number and does not authorize start, migration, bootstrap, or ingress.
- **Read-only preflight and inputs:** Verify app files against the accepted commit/tree, exact approved image digest, root-owned target rules, protected environment source, and selected node-IP evidence. Require the container's `EVENTSALES_NODE_IP` to equal its `ipv4_address` on `eventsales-prod_eventsales_data`. Confirm `eventsales-app` is an alias only on the data network and absent from the edge network. Compose invocations must use `--env-file /dev/null`; `EVENTSALES_DEPLOY_ENV_FILE` must identify the protected runtime file through a separately approved path.
- **Permitted / forbidden:** Stage reviewed bytes and the protected environment file without printing values. The overlay may be staged but not applied. Do not start/create the app, publish a host port, migrate, bootstrap, or attach the app to either network.
- **Authority consumption / side effects:** E authorization is consumed at the first staged app byte or environment-file write. Side effects are staged app artifacts and a protected environment file only.
- **Success evidence / resulting state:** Record source SHA/tree, digest identity, byte identity, node-IP decision reference, environment variable names only, protected ownership/mode, and structural Compose proof with secret values suppressed. Result: `APP_STAGED`.
- **STOP / failure evidence:** A started transition that fails enters `BLOCKED_E`. Stop for an unapproved digest, unproven node candidate, IP/address mismatch, edge alias, missing protected environment source, value leakage, or a wrapper/stage boundary failure. Preserve partial staged bytes and metadata.
- **Rerun / rollback / next gate:** Never overwrite partial stage state. A replacement stage requires review and new authority. Removing staged files requires separate authorization. F/V7 remains unauthorized.

### F / V7: run the one-shot migration

- **Entering state:** `APP_STAGED`.
- **Prior acceptance:** V5 data plane and V6 image are accepted; E staging is verified; the app is absent; no host app port exists; current backup/restore strategy and destructive migration risk have been reviewed.
- **Authority:** A separate, one-shot V7 migration authorization is required. It identifies the exact digest, direct database target, migration operation, and backup/compatibility decision.
- **Read-only preflight and inputs:** Confirm PostgreSQL is healthy and restart-free, `event_sales_prod` and `eventsales_migrator` match the accepted structural proof, the current backup/restore evidence is reviewed, the exact app digest is staged, and no app container or host port exists. The migration environment carries `DIRECT_DATABASE_URL` to PostgreSQL as `eventsales_migrator`. Runtime `DATABASE_URL` through PgBouncer is not migration authority.
- **Permitted / forbidden:** Invoke only `EventSales.Release.migrate()` from the approved digest. Do not invoke bootstrap, normal app start, a combined migration/bootstrap operation, or a public/host-published container.
- **Authority consumption / side effects:** V7 is consumed when the migration entrypoint is invoked. The side effect is the schema/data migration in `event_sales_prod`.
- **Success evidence / resulting state:** Record the image digest, migration exit status, safe output, and accepted `schema_migrations` state. Result: `MIGRATED`.
- **STOP / failure evidence:** On any failure, preserve the migration output and container/evidence state, then inspect `schema_migrations` under separate read-only authority. Never blindly rerun, auto-repair, or automatically roll back.
- **Rerun / rollback / next gate:** A failure enters `BLOCKED_F`. A retry needs forensic review and a new V7 authorization. Database rollback is never automatic; it needs a current backup, data-compatibility review, and separate destructive authority. G/V8 remains unauthorized.

### G / V8: start the temporary private bootstrap app

- **Entering state:** `MIGRATED`.
- **Prior acceptance:** V7 migration is accepted; the same digest remains approved; the data plane is accepted and restart-free; the app has no host port.
- **Authority:** A separate V8 authorization covers only creation/start of the temporary private bootstrap app. H's bootstrap invocation requires another explicit authorization.
- **Read-only preflight and inputs:** Verify the exact digest, runtime credentials, bootstrap-only values, data network/node identity, and no host-port configuration. Use the runtime and bootstrap-only variable classes from the accepted runtime contract. Exclude migration-only credentials, including `DIRECT_DATABASE_URL` and migrator credentials, unless a separately reviewed exception names the exact need.
- **Permitted / forbidden:** Start the same approved digest privately with runtime plus temporary bootstrap variables only. Do not publish a port, apply the ingress overlay, migrate, invoke bootstrap, or stage OLS changes.
- **Authority consumption / side effects:** G authorization is consumed at the first app container create/start operation. Side effects are one temporary private app container with temporary bootstrap credentials in its environment.
- **Success evidence / resulting state:** Record the digest, private network membership, no host ports, health/readiness, zero restarts, and environment variable names only. Result: `BOOTSTRAP_APP_RUNNING`.
- **STOP / failure evidence:** Stop for wrong digest, any public/host port, migration-only credential, D0/data-plane drift, unhealthy app, restart, or environment leakage. Preserve container identity, logs, and safe state.
- **Rerun / rollback / next gate:** Failed start enters `BLOCKED_G`; preserve state and do not recreate or remove automatically. A new attempt needs review and new authorization. H/V8 bootstrap invocation remains unauthorized.

### H / V8: invoke explicit bootstrap

- **Entering state:** `BOOTSTRAP_APP_RUNNING`.
- **Prior acceptance:** G is accepted; the temporary app is ready privately from the approved digest; no host port exists; the migration state remains accepted.
- **Authority:** A separate, one-shot authorization is required for `EventSales.Release.bootstrap()`. G's start authorization does not authorize this operation.
- **Read-only preflight and inputs:** Reconfirm app digest, private health/readiness, zero restarts, database reachability through the runtime path, and the expected bootstrap variable names. Confirm no migration-only credentials are present unless an exact reviewed exception permits them.
- **Permitted / forbidden:** Invoke only `EventSales.Release.bootstrap()`. It performs admin and source-system bootstrap and does not run migrations. This temporary bootstrap app is not the final runtime. Do not run `migrate()`, `migrate_and_bootstrap()`, publish a host port, or perform final runtime recreation in H.
- **Authority consumption / side effects:** H authorization is consumed at the bootstrap invocation. Side effects are the authorized initial admin and source-system bootstrap records.
- **Success evidence / resulting state:** Record safe exit/output and bootstrap completion without recording email, password, URL credentials, or customer data. Result: `BOOTSTRAPPED`.
- **STOP / failure evidence:** Failure enters `BLOCKED_BOOTSTRAP`. Preserve output, app identity, environment-name inventory, and resulting database state. Idempotency does not authorize a blind rerun.
- **Rerun / rollback / next gate:** No retry, cleanup, or rollback under the consumed authority. New forensic review and authorization are required. I remains unauthorized.

### I: recreate the final private runtime

- **Entering state:** `BOOTSTRAPPED`.
- **Prior acceptance:** H is accepted; migration and bootstrap completed; the same exact image digest remains approved; the data plane and D0 remain stable.
- **Authority:** A separate I authorization permits recreation of the app as the final private runtime, without host ports. It does not authorize the J proof or K ingress.
- **Read-only preflight and inputs:** Derive the exact environment-name allow/deny inventory from the accepted `config/runtime.exs`, `rel/env.sh.eex`, `deploy/vps/app/compose.yaml`, `deploy/vps/app/scripts/probe-private.sh`, and runtime documentation for the reviewed source commit. Compare names only. Required runtime values include `DATABASE_URL`, `REDIS_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `WEBHOOK_PATH_TOKEN`, `WOOCOMMERCE_WEBHOOK_SECRET`, and `RELEASE_COOKIE`; the runtime URL must use `eventsales_runtime` through PgBouncer at `pgbouncer:6432/event_sales_prod`. Set `POOL_SIZE=20`. Redis uses the `eventsales_runtime` identity and `eventsales:prod:*`; set `HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true` and `WEBHOOK_RATE_LIMIT_ENABLED=true`, with the current `HOT_STATE_REDIS_SNAPSHOT_TTL_MS=3600000`, `WEBHOOK_RATE_LIMIT_WINDOW_MS=60000`, and `WEBHOOK_RATE_LIMIT_MAX_REQUESTS=120` defaults unless an accepted runtime change supersedes them. Compose supplies `PHX_SERVER`, `PORT=4000`, `POOL_SIZE=20`, `DNS_CLUSTER_QUERY=eventsales-app`, `EVENTSALES_NODE_IP`, and both webhook-buffer flags as false. Record the exact accepted name inventory and any feature-specific optional values by name only.
- **Permitted / forbidden:** Recreate from the same digest using runtime-only values. Exclude `DIRECT_DATABASE_URL`, migrator credentials, backup credentials, PostgreSQL bootstrap credentials, and every `EVENTSALES_BOOTSTRAP_*` variable. The current bootstrap names are `EVENTSALES_BOOTSTRAP_ADMIN_EMAIL`, `EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD`, `EVENTSALES_BOOTSTRAP_ADMIN_NAME`, `EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD`, `EVENTSALES_BOOTSTRAP_SOURCE_NAME`, and `EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL`. The current private probe also denies `POSTGRES_PASSWORD`, `POSTGRES_PASSWORD_FILE`, `PGPASSWORD`, `PGPASSFILE`, `EVENTSALES_SECRET_DIR`, `EVENTSALES_MIGRATOR_PASSWORD`, `EVENTSALES_BACKUP_PASSWORD`, and `POSTGRES_BOOTSTRAP_PASSWORD`. No data-plane secret files are mounted into the app. Do not add unreviewed feature-specific credentials or enable catalogue auto-Apply, catalogue change receivers, public cutover controls, or webhook degraded buffering.
- **Authority consumption / side effects:** I authorization is consumed at the first final-runtime recreate operation. Side effect is replacement of the temporary container with a private runtime container using the same image digest and runtime-only environment.
- **Success evidence / resulting state:** Record the same digest, exact variable names only, absence of the denylist, `DATABASE_URL`/Redis identity by role and destination only, private network identity, no host port, health/readiness, and zero restarts. Never print URL values. Result: `FINAL_PRIVATE_RUNNING`.
- **STOP / failure evidence:** Stop for any forbidden variable, missing required runtime value, wrong database/Redis role or path, wrong digest, host port, changed network identity, unhealthy app, restart, or D0/data-plane drift. Preserve safe container metadata and logs.
- **Rerun / rollback / next gate:** Failed recreation enters `BLOCKED_I`; do not recreate again or remove evidence without new review and authorization. App rollback requires a previously approved digest and schema-compatibility review. J/V9 remains unauthorized.

### J / V9: prove the private runtime

- **Entering state:** `FINAL_PRIVATE_RUNNING`.
- **Prior acceptance:** I is accepted; the app has the approved digest, runtime-only environment, no host port, and zero restarts; data plane and D0 are accepted.
- **Authority:** A separate V9 proof authorization permits the accepted `probe-private.sh` only. Privileged execution requires the reviewed root wrapper and staged immutable probe bytes.
- **Read-only preflight and inputs:** Confirm probe identity, root wrapper, exact app/data-plane IDs, image digest, environment-name inventory, app and data-plane restart counts, D0 3/2/1 identity, host Redis baseline, and no host ports.
- **Permitted / forbidden:** Run `probe-private.sh`; do not duplicate its proof logic. It must establish security/resources, private networks and node IP, data-only `eventsales-app` alias, forbidden-env absence, `Node.alive?`, `event_sales@EVENTSALES_NODE_IP`, PubSub, DNS resolution, BEAM/EPMD binds, `PrivateRuntimeSmoke`, private health/readiness, and data-plane/D0 stability. Do not add a host port or OLS route.
- **Authority consumption / side effects:** V9 is consumed at the probe invocation. The accepted smoke may create bounded proof data through the approved runtime adapters; it may not restart or recreate any service.
- **Success evidence / resulting state:** Preserve safe probe output and exact identities, with zero app/data-plane/D0 restarts and unchanged host Redis baseline. Result: `PRIVATE_ACCEPTED`.
- **STOP / failure evidence:** Stop on any probe failure, restart, wrong identity, forbidden env, wrong network/IP/alias, BEAM/EPMD bind mismatch, health/readiness failure, host port, D0 drift, or host Redis change. Preserve probe output, IDs, and resulting state.
- **Rerun / rollback / next gate:** Failed V9 enters `BLOCKED_J`; no blind probe rerun or repair. A new review and authorization are required. Removing the private app or its data is not an automatic rollback. K/V10 remains unauthorized.

### K / V10: publish and prove loopback ingress

- **Entering state:** `PRIVATE_ACCEPTED`.
- **Prior acceptance:** V9 is accepted, app/data plane/D0 have zero unexplained restarts, and the host has no conflicting port 4100 listener.
- **Authority:** A separate V10 authorization permits applying only `deploy/vps/app/compose.ingress.yaml` and running the accepted `probe-loopback.sh`. It grants no OLS authority.
- **Read-only preflight and inputs:** Confirm the overlay adds exactly `127.0.0.1:4100:4000`, no other service or config changes, and the accepted image, security, resource, env, network, and D0 evidence.
- **Permitted / forbidden:** Apply the ingress overlay, then use `probe-loopback.sh` without duplicating its proof logic. Prove exact binding, no wildcard IPv4/IPv6 listener, external-interface denial, `/health` and `/ready` HTTP 200, security/resource/env continuity, and data-plane/D0/host Redis continuity. Do not change OLS or public DNS/routes.
- **Authority consumption / side effects:** V10 is consumed at the first app recreation that applies the overlay. Side effect is the loopback-only host port. No data service may publish a host port.
- **Success evidence / resulting state:** Preserve exact binding and HTTP proof, external-denial result, app identity and zero restarts, plus unchanged data-plane, D0, and host Redis evidence. Result: `LOOPBACK_ACCEPTED`.
- **STOP / failure evidence:** Stop for wildcard bind, any non-loopback exposure, external-interface connection, wrong port mapping, health/readiness failure, env/security drift, or any app/data/D0 restart. Preserve socket, Docker, HTTP, and identity evidence.
- **Rerun / rollback / next gate:** Failed V10 enters `BLOCKED_K`; no automatic overlay removal or recreate. A loopback rollback requires separate ingress authority. L/V11 OLS staging remains unauthorized.

### L / V11: stage and prove the OpenLiteSpeed upstream

- **Entering state:** `LOOPBACK_ACCEPTED`.
- **Prior acceptance:** K is accepted; loopback health/readiness and external denial pass; a concrete public `PHX_HOST` has separate owner approval; the prior OLS configuration identity is available.
- **Authority:** A separate V11 authorization covers the exact reviewed OLS staging and upstream-proof actions. It does not authorize DNS changes or public route cutover. Do not invent an OLS path or command.
- **Read-only preflight and inputs:** Capture the old OLS bytes and identity in the later approved evidence location. Review candidate configuration that points only to `127.0.0.1:4100`, preserves forwarded host and HTTPS scheme semantics, and supports LiveView WebSocket upgrade. Confirm the accepted OLS syntax-check method, reload method, and rollback bytes before writing.
- **Permitted / forbidden:** Stage only the reviewed upstream configuration. Run its syntax check before any separately authorized reload. Prove upstream and WebSocket behavior while public routing remains unchanged. Do not change DNS, public routes, app/data-plane config, or loopback ingress.
- **Authority consumption / side effects:** Staging authority is consumed at the first OLS byte write. Reload authority, if required for the V11 proof, must be explicit and is consumed at reload. Side effects are limited to the staged OLS bytes and the reviewed reload; there is no public cutover.
- **Success evidence / resulting state:** Record old and candidate config identities, syntax result, upstream address, forwarded-header and WebSocket proof, and rollback-byte availability. Result: `OLS_STAGED`.
- **STOP / failure evidence:** Stop if the OLS target/path or syntax/reload method lacks accepted authority, old bytes cannot be captured, syntax fails, upstream is not loopback, headers/WebSocket fail, or public routing changes. Preserve old and candidate bytes plus non-secret diagnostics.
- **Rerun / rollback / next gate:** Failure enters `BLOCKED_L`; do not reload, restore, or retry automatically. OLS rollback restores the captured accepted bytes, passes syntax check, and uses separate reload authority. M/V12 public cutover remains unauthorized.

### M / V12: public cutover

- **Entering state:** `OLS_STAGED`.
- **Prior acceptance:** V11 OLS proof is accepted; all prior states remain accepted; current backup/restore evidence and rollback assets are available; app/data-plane/D0 restarts are explained and accepted; the approved public host is established.
- **Authority:** A separate, explicit V12 owner authorization is required for the named public route/cutover action. No previous merge, image approval, migration, bootstrap, or ingress authorization covers it.
- **Read-only preflight and inputs:** Recheck HTTPS endpoint identity, health/readiness, application pages, LiveView WebSocket path, webhook test plan, admin authentication, protected Oban access, job success/retry plan, PgBouncer/Redis identities, absence of data-service host ports, host Redis and D0 baseline, and rollback readiness.
- **Permitted / forbidden:** Enable only the approved public route. Prove HTTPS health/readiness/pages, LiveView WebSocket, valid webhook acceptance and invalid signature rejection, admin authentication, protected Oban access, job success and retry, database access via PgBouncer, and Redis runtime behavior. Confirm no PostgreSQL/PgBouncer/Redis host ports and unchanged host Redis/D0. Do not broaden scope or modify data-plane services.
- **Authority consumption / side effects:** V12 is consumed at the first public route/DNS change or public traffic enablement. Side effect is public EventSales traffic reaching the accepted OLS-to-loopback path.
- **Success evidence / resulting state:** Preserve only safe endpoint test results, identity references, job outcomes without customer data, restart state, data-service port proof, and available rollback references. Result: `PUBLIC_ACCEPTED`.
- **STOP / failure evidence:** Stop for any failed public proof, unexplained app/data/D0 restart, direct data-service exposure, host Redis change, authentication/signature failure, or unavailable rollback. Preserve request IDs and redacted evidence only; no customer data or secret values.
- **Rerun / rollback / next gate:** Failure enters `BLOCKED_M`; no automatic retry or cutover reversal. Public rollback requires separate route/OLS authority. Database rollback remains separate and never automatic. N closeout remains unauthorized.

### N: closeout

- **Entering state:** `PUBLIC_ACCEPTED`.
- **Prior acceptance:** V12 owner acceptance and all prior gate records are present; no unresolved failure or unexplained restart remains.
- **Authority:** A separate closeout authorization permits a read-only identity inventory and owner acceptance. It grants no cleanup, rotation, redeploy, or rollback authority.
- **Read-only preflight and inputs:** Gather repository SHA/tree; approved image digest; app and data container IDs; production network and volume identities; restart counts; private, loopback, public and OLS proof references; backup/restore evidence reference; final secret filename inventory; temporary credential absence; D0 three-container/two-network/one-volume baseline; host Redis baseline; and rollback asset identities.
- **Permitted / forbidden:** Record identities and names only. Never output secret values or hashes, `DATABASE_URL`, `REDIS_URL`, release-cookie values, or password verifiers. Do not remove temporary evidence, containers, volumes, credentials, or rollback assets in closeout.
- **Authority consumption / side effects:** Closeout authority is consumed at the first inventory read. The inventory has no production side effect. The owner acceptance is a separate explicit decision.
- **Success evidence / resulting state:** When the owner accepts the complete evidence set, record `D1_PRODUCTION=ACCEPTED` and result `CLOSED`. Without that decision, retain `PUBLIC_ACCEPTED`; do not claim closeout or production acceptance.
- **STOP / failure evidence:** A started closeout that fails enters `BLOCKED_N`. Stop for missing identities, temporary credentials still present, any secret/value/hash exposure, missing backup or rollback evidence, D0/host Redis drift, unexplained restarts, or a missing owner decision. Preserve the safe inventory and gap list.
- **Rerun / rollback / next gate:** A failed closeout needs a new review and authorization for any further action. N has no automatic rollback and no next gate. D0 is never a rollback target.

## Rollback boundaries

Treat application, loopback ingress, OpenLiteSpeed/public routing, database, secrets, and data plane as separate rollback authorities.

- **Application:** Revert only to a previously approved immutable digest. Check schema compatibility first. Production never builds an older source tree on-host.
- **Loopback ingress:** Removing the ingress overlay or recreating the app requires separate ingress authority and a new loopback proof.
- **OpenLiteSpeed/public route:** Restore only the captured accepted bytes, syntax-check them, and obtain separate reload or route authority. DNS/public routing has its own cutover authority.
- **Database:** Never roll back automatically. Require a current backup, data/schema compatibility review, and explicit destructive authority. Preserve migration evidence. A failed migration is not authority to rerun or roll back.
- **Secrets:** If a value is exposed, contain access and obtain separate rotation authority. Do not print, hash, reuse, or regenerate over a partial secret set.
- **Data plane:** Preserve PostgreSQL volume and proof artifacts. D0 is never a rollback destination. Routine rollback never uses `docker compose down -v`, `docker compose down --volumes`, production volume removal, or volume pruning.

## Runtime and scaling constraints

- Hot state remains in the existing ETS/GenServer path, with Phoenix PubSub and LiveView push. Redis is warm shared state; PostgreSQL is durable truth; Oban handles heavy asynchronous work.
- The Redis sorted-set rate limiter uses the current 60-second default window. Hot-state Redis snapshots use string/value keys with the current one-hour default TTL. The webhook degraded-mode Redis buffer remains disabled.
- Readiness stays ETS-backed. Do not add request-time database readiness polling. Do not introduce peak-time large analytics scans.
- `100k` concurrent users is not certified by D1. Before making that claim, require multi-node DNSCluster/BEAM/PubSub proof, load tests, read-replica or materialized/cached analytics, measured PgBouncer sizing, flash-sale queue/hold/rate-limit architecture where needed, cache stampede protection, and measured API/checkout p99 evidence.

## Related authority

- [D1 architecture approval](../superpowers/specs/2026-10-20-d1-vps-production-architecture-approval.md)
- [D1 architecture](../superpowers/specs/2026-10-20-d1-vps-production-architecture-design.md)
- [R1 node ruling](../superpowers/specs/2026-10-21-d1-vps-production-cluster-node-ruling.md)
- [D1 implementation plan](../superpowers/plans/2026-10-20-d1-vps-production-implementation.md)
- [Data-plane repository contract](../../deploy/vps/data-plane/README.md)
- [App repository contract](../../deploy/vps/app/README.md)
- [Migration and release behavior](migrations-and-release.md)
- [Runtime configuration](runtime-config.md)
- [PgBouncer strategy](pgbouncer.md)
- [Database backup and restore guidance](../runbooks/database-backup-restore.md)
