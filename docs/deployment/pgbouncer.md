# PgBouncer Strategy

## Historical Railway topology

Slice 24.0 connected EventSales, release migrations, and Oban directly to Railway's private managed PostgreSQL endpoint. That record describes the earlier deployment and does not define the approved D1 target.

## Approved D1 target

The D1 production target uses PgBouncer transaction pooling for normal `DATABASE_URL` runtime traffic. Oban uses `Oban.Notifiers.PG` so notifications do not depend on PostgreSQL session-level `LISTEN/NOTIFY`. Migrations use direct PostgreSQL through `DIRECT_DATABASE_URL`; R2 will define their separate entrypoints.

The target configuration sets `max_prepared_statements=200`. Keep Postgrex's named prepared statements enabled until the later private runtime proof establishes whether any adjustment is needed. Do not claim that the production PgBouncer has been deployed or that transaction-pooling compatibility has been runtime-proven.

For D1 clustering, the deployment contract places the app's `eventsales-app` DNS alias on the internal EventSales data network, not the edge network. The production release uses the long node name `event_sales@${EVENTSALES_NODE_IP}` and an externally supplied cookie. The approved internal IP is selected later after a read-only VPS network collision audit. When configured, `rel/env.sh.eex` sets `ERL_EPMD_ADDRESS` to that IP and configures long-running release nodes and distributed helper nodes to use it with `inet_dist_use_interface`. R4 must verify the actual BEAM and EPMD listening sockets, confirm that the edge IP has no distribution listener, and confirm that no distribution port is published to the host. This release contract is configured in R1 but is not runtime-proven.

The previous direct/session-pooling topology remains historical evidence. It does not authorize changing D1's selected transaction-pooling model.
