# EventSales production app Compose

These files define the repository contract for the separate `eventsales-app`
Compose project. They are inert repository artifacts. R4.5 does not run or
create containers, select production values, or authorize production work.

A repository merge grants none of these authorities:

```text
R4.5 repository merge != deployment authority
R4.5 repository merge != image approval
R4.5 repository merge != migration authority
R4.5 repository merge != bootstrap authority
R4.5 repository merge != ingress authority
R4.5 repository merge != OLS authority
```

## Private app definition

`compose.yaml` is always the private definition. It contains one `app` service,
uses the required `EVENTSALES_IMAGE_REF`, and has no `build:` directive or host
port. The selected image must be an approved immutable reference in this form:

```text
ghcr.io/jcschoeman96/eventsales@sha256:<64-lowercase-hex>
```

R4.5 does not select a digest. The app joins the existing external networks
`eventsales-prod_eventsales_data` and `eventsales-prod_eventsales_edge`. Only
the data network has the `eventsales-app` clustering alias. The edge network
has no `eventsales-app` alias. No Erlang distribution or EPMD port is published
to the host.

`EVENTSALES_NODE_IP` is required by Compose and supplies both the data-network
static address and the container's release node identity. Its production value
must come from the later authorized, read-only VPS Docker-network collision
audit. R4.5 does not choose an address or subnet.

Compose requires `EVENTSALES_DEPLOY_ENV_FILE` to select the protected runtime
environment file. The production file is root-owned, mode `0400`, and contains
runtime-only values. Pass `--env-file /dev/null` to every Compose invocation
so Compose does not load the repository `.env` file. The Compose-pinned
structural settings override values in the selected file:

- `PHX_SERVER=true`, `PORT=4000`, `POOL_SIZE=20`, and
  `DNS_CLUSTER_QUERY=eventsales-app`;
- `WEBHOOK_REDIS_BUFFER_ENABLED=false` and
  `WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED=false`;
- `EVENTSALES_NODE_IP`, using the same interpolation value as the data-network
  address.

The final long-running runtime must not contain `DIRECT_DATABASE_URL`,
PostgreSQL bootstrap credentials, the `eventsales_migrator` password, or the
`eventsales_backup` password. It must also exclude these bootstrap-only
variables:

```text
EVENTSALES_BOOTSTRAP_ADMIN_EMAIL
EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD
EVENTSALES_BOOTSTRAP_ADMIN_NAME
EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD
EVENTSALES_BOOTSTRAP_SOURCE_NAME
EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL
```

R4.5 adds no migration or bootstrap command, service, or container. Secret
values do not belong in these repository files.

The container runs as `eventsales` with a read-only root filesystem, init
process, `unless-stopped` restart policy, all capabilities dropped, and
`no-new-privileges`. Its only writable path is a 64 MiB `/tmp` tmpfs mounted
`rw,noexec,nosuid,nodev`. The app limit is 4 CPUs, 2 GiB memory, and 512 PIDs.
The Docker healthcheck runs `bin/event_sales pid` in exec form. It proves
process liveness only. It does not call HTTP, PostgreSQL, Redis, or Ecto.
Private readiness remains a later proof and keeps the existing ETS-backed
`/ready` behavior.

## Loopback ingress overlay

`compose.ingress.yaml` adds only `127.0.0.1:4100:4000` to `app`. Apply it only
after the private runtime has been accepted. The overlay does not grant OLS
configuration or public routing authority. No OLS authority follows from
accepting loopback ingress.

## Separate operational lifecycles

These lifecycles require their own later authorization and are not implemented
by R4.5:

- **Migration lifecycle:** a separately authorized, one-shot migration uses
  `DIRECT_DATABASE_URL` with the migrator role. It is not part of normal app
  startup or either Compose file.
- **Bootstrap lifecycle:** a separately authorized bootstrap temporarily uses
  the bootstrap-only values. After success, remove them and recreate the
  private app with the same approved image before private acceptance.
- **Final runtime lifecycle:** run the long-lived app privately with runtime
  credentials only. Prove it healthy, ready, and private before accepting it.
- **Loopback ingress lifecycle:** after private acceptance, add the overlay,
  prove local health and external denial, then accept loopback ingress.
- **OLS lifecycle:** configure and verify OLS in a separate reviewed transition.
  Public routing and cutover remain outside R4.5.

### RuntimeApp states

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

```text
ANY_FAILED_TRANSITION
  -> BLOCKED
```

`BLOCKED` requires review. Preserve evidence and do not blindly recreate or
repair the app.

### LoopbackIngress states

```text
ABSENT
  -> LOOPBACK_PUBLISHED
  -> LOCAL_HEALTHY
  -> EXTERNAL_DENIAL_PROVEN
  -> ACCEPTED
```

```text
ANY_FAILED_TRANSITION
  -> BLOCKED
```

`BLOCKED` requires review. Preserve evidence and do not blindly recreate or
repair ingress.

## Performance and scaling scope

R4.5 changes deployment structure only. It changes no hot, warm, or cold data
layer; PostgreSQL indexes or queries; Redis structures, commands, TTLs, or cache
invalidation; Phoenix PubSub behavior; or Oban topology. Runtime `POOL_SIZE` is
20, and the PgBouncer backend cap remains 16. The app limits are 4 CPUs, 2 GiB
memory, and 512 PIDs. The base host-port state is private; the later loopback
port is `127.0.0.1:4100`. R4.5 makes no 100k-concurrency claim.

Compose rendering with safe fixture values checks repository configuration
only. Do not use `pull`, `build`, `create`, `up`, `start`, `run`, or `exec` as
part of R4.5 verification. Later root or Docker operations remain subject to a
separate review under the `agentops` privilege boundary.
