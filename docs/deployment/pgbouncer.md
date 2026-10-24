# PgBouncer strategy

## Historical Railway topology

Slice 24.0 connected EventSales, release migrations, and Oban directly to Railway's private managed PostgreSQL endpoint. That record describes the earlier Railway deployment and does not define the D1 VPS target.

## D1 runtime and migration paths

For D1 production, runtime `DATABASE_URL` uses PgBouncer transaction pooling and the `eventsales_runtime` role. Migration `DIRECT_DATABASE_URL` connects directly to PostgreSQL as `eventsales_migrator`. The direct migration path is not the normal runtime path.

The accepted pool settings are:

```ini
pool_mode = transaction
max_client_conn = 64
default_pool_size = 12
reserve_pool_size = 4
max_db_connections = 16
max_user_connections = 16
max_prepared_statements = 200
```

Keep named Postgrex/Ecto prepared statements enabled. The repository's accepted R4 probes exercise runtime authentication, DML, DDL denial, direct runtime-client PostgreSQL authentication denial, transaction backend reuse, and the named prepared-statement protocol. Do not switch to `prepare: :unnamed` without failure evidence and a new review. The probes exist in the repository; production execution and acceptance remain unproven until the separately authorized V5 gate passes.

Oban runtime notifications use `Oban.Notifiers.PG`, so notification delivery does not depend on session-level PostgreSQL `LISTEN/NOTIFY` through the transaction pool. Oban's database-backed job and leadership behavior remains separate from its notifier.

## R1 release identity and cluster boundary

`R1-RULING-01` locks:

```text
RELEASE_DISTRIBUTION=name
RELEASE_NODE=event_sales@EVENTSALES_NODE_IP
CLUSTER_DNS_QUERY=eventsales-app
CLUSTER_NETWORK=eventsales-prod_eventsales_data
```

The ruling names this setting `CLUSTER_DNS_QUERY`; the current Compose/runtime environment binding is `DNS_CLUSTER_QUERY=eventsales-app`. The `eventsales-app` DNS alias belongs only to `eventsales-prod_eventsales_data`, not the edge network. The approved `EVENTSALES_NODE_IP` is selected only after a read-only VPS Docker-network collision audit proves the candidate safe. The same address is used as the data-network `ipv4_address`. Never use Docker `HOSTNAME` as node identity or place the cluster alias on the edge network.

The release configuration directs EPMD and the BEAM distribution listener to the approved data-network address. The private runtime proof must inspect their actual sockets, confirm `Node.alive?`, the exact node name, PubSub, DNS resolution, and absence of a distribution host port. Configuration alone does not prove runtime binding. Production clustering has not been proven; multi-node behavior remains a separate scaling gate.

See the [VPS production runbook](vps-production.md) for the separate migration, private proof, ingress, and authorization transitions. No statement here authorizes production deployment or claims that PgBouncer is running in production.
