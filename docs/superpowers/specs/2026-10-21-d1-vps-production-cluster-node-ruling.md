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

SEC01_BANDIT_UPGRADE=ACCEPTED
SEC01_ACCEPTED_HEAD=ffcbf5ecf3904811931cfdd50393c9b380f0d52e
SEC01_ACCEPTED_TREE=e21204dcd2f4587389e2dc32d5ef2f4d5cce59b2
CURRENT_BANDIT=1.13.1
THOUSAND_ISLAND=1.6.0
CVE_2026_105659_REMEDIATED=YES
CVE_2026_105660_REMEDIATED=YES
DEPENDENCY_AUDIT=PASS
HEX_AUDIT=PASS
QUALITY_FAST=PASS
FULL_TEST_SUITE=3050 tests, 0 failures, 1 excluded
GITHUB_CONTENT_REVIEW=PASS
GITHUB_SIGNATURE=PASS
GITHUB_CI_STATUS=NOT_RUN_ON_THIS_HEAD
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

## Bandit security status

Bandit 1.12.5 was the vulnerable version that prompted SEC-01. The accepted SEC-01 commit updates the requirement and lock to Bandit 1.13.1, with Thousand Island 1.6.0. The dependency audit, Hex audit, quality gate, and full test suite passed. GitHub content and signature review passed. GitHub CI did not run on this head. Existing Ash notification and catalog post-commit cache/PubSub test warnings were not addressed by SEC-01 and are not recorded as resolved here.
