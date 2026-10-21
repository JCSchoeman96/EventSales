# D1 VPS Production Cluster Node Ruling

```text
RULING=R1-RULING-01

SUPERSEDES=
  any D1 design wording requiring Docker HOSTNAME-derived node identity
  any D1 design wording placing the eventsales-app clustering alias on the edge network

RELEASE_DISTRIBUTION=name
RELEASE_NODE=event_sales@EVENTSALES_NODE_IP

CLUSTER_DNS_QUERY=eventsales-app
CLUSTER_NETWORK=eventsales-prod_eventsales_data
EDGE_NETWORK_CLUSTER_ALIAS=FORBIDDEN

EVENTSALES_NODE_IP_SOURCE=
  production deployment contract; actual value chosen later after VPS network audit

MULTI_NODE_RUNTIME_PROOF=NOT_YET_PERFORMED

SEC01_BANDIT_UPGRADE_REQUIRED=YES
CURRENT_BANDIT=1.12.5
TARGET_BANDIT=1.13.1
SEC01_EXECUTION=AFTER_R1_BEFORE_R2
SEC01=REQUIRED_NOT_YET_AUTHORIZED_FOR_EXECUTION
```

## Node identity and network boundary

D1 production uses Erlang long names. The node basename is `event_sales`; each node's approved internal IPv4 address supplies the host portion of the node name. The locked `dns_cluster` 0.2.0 implementation resolves the configured query to IP addresses and constructs peer node names from the local basename and each address. The release uses `RELEASE_NODE=event_sales@${EVENTSALES_NODE_IP}` and receives `RELEASE_COOKIE` from an external production secret.

For the single-node MVP, R4 will choose `EVENTSALES_NODE_IP` only after a read-only VPS Docker-network collision audit. The app's internal network `ipv4_address` must equal that value. Do not derive the node identity from Docker `HOSTNAME`, invent a DNS suffix, use short names, or hard-code an IP or cookie.

The deployment contract places the `eventsales-app` alias only on `eventsales-prod_eventsales_data`, the internal EventSales data network. When `EVENTSALES_NODE_IP` is set, `rel/env.sh.eex` configures EPMD with that address and configures long-running release nodes and distributed helper nodes to use it with `inet_dist_use_interface`. This configures the intended bind address; it does not prove the runtime socket state. The deployment contract must not publish an Erlang distribution port to the host.

R1 configures this release contract. It does not create production networking or prove production or multi-node clustering.

## Required private runtime proof

Before production or multi-node clustering is accepted, the private runtime proof must verify:

- The BEAM distribution listener is bound to `EVENTSALES_NODE_IP`.
- EPMD is bound to `EVENTSALES_NODE_IP`, with any unavoidable loopback listener recorded.
- No distribution listener is bound to the app's `eventsales_edge` IP.
- No Erlang distribution port is published to the host.
- `eventsales-app` resolves to the expected data-network peer IP set.

The actual production subnet and IP, Docker interface assignment, BEAM and EPMD socket addresses, production peer discovery, and multi-node clustering remain unproven until that gate passes.

## Bandit security follow-up

The locked Bandit 1.12.5 release is not accepted for production while the reviewed security advisories remain unresolved. SEC-01 is a separate required task targeting Bandit 1.13.1 after R1 and before R2. This ruling records the queued requirement only; it does not authorize or perform the dependency upgrade. R1 does not modify `mix.exs` or `mix.lock` for SEC-01.
