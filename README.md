# EventSales

## Local development

```bash
bash scripts/dev_local.sh
```

This verifies local WordPress and workstation-shared PostgreSQL DEV and Redis
DEV, applies development migrations, and starts native Phoenix at
[`127.0.0.1:4001`](http://127.0.0.1:4001).

The Dockge `dev-core` stack owns workstation services:

| Service | Endpoint |
| --- | --- |
| PostgreSQL DEV | `127.0.0.1:55432` |
| PostgreSQL TEST | `127.0.0.1:55433` |
| Redis DEV | `127.0.0.1:56379` |
| Redis TEST | `127.0.0.1:56380` |

EventSales uses PostgreSQL roles `eventsales_dev` and `eventsales_test` for
separate `event_sales_dev` and `event_sales_test` databases. Put the role
passwords in ignored `.env.local`; never use the PostgreSQL `postgres`
superuser for the application.

Operational commands:

```bash
bash scripts/dev_local.sh status
bash scripts/dev_local.sh doctor
bash scripts/dev_local.sh test
bash scripts/dev_local.sh quality-pr
bash scripts/dev_local.sh quality-ci
bash scripts/dev_local.sh catalogue-dry-run
bash scripts/dev_local.sh catalogue-dry-run --fresh
bash scripts/dev_local.sh stop
```

`catalogue-dry-run` prepares the local infrastructure and safely reuses the
current ready full-feed plan without starting Phoenix or applying changes.
Pass `--fresh` only when the current localhost WordPress catalogue state must
be rediscovered. Fresh mode supersedes only a ready dry run, preserves its
history and findings, reuses any discovery already in progress, and never
interrupts an applying run or Applies catalogue changes.

`variation_mapping_required` is a structural warning for a variable product,
not a count of unresolved variations. Review the exact product/variation rows
in Catalog Sync to determine whether each identity is already mapped, safely
planned, conflicting, ambiguous, or requires a manual exception. Manual
variation resolution revokes the ready plan before writing a mapping; always
run `bash scripts/dev_local.sh catalogue-dry-run --fresh` afterward. This
review workflow never queues Apply.

The test command creates and migrates a uniquely named EventSales test database
on PostgreSQL TEST. Parallel partitions run as separate Mix processes with
matching numeric database suffixes. The `quality-pr` command runs the
repository's full local gate on another uniquely named TEST database.
The tests use in-memory Redis adapters; they do not connect to shared Redis.

`Ctrl+C` stops Phoenix. `bash scripts/dev_local.sh stop` stops only the native
Phoenix process. Workstation PostgreSQL and Redis remain owned by Dockge's
`dev-core` stack. The script loads only `.env.local` and never sources the root
`.env`.

## Docker deployment contract

The repository-owned [`compose.yaml`](compose.yaml) defines the application
container for Docker Compose deployment. It does not define PostgreSQL or Redis.
Supply reachable external service URLs and production secrets through a
protected deployment environment file. Set its absolute path in
`EVENTSALES_DEPLOY_ENV_FILE`. Pass `--env-file /dev/null` so Compose does not
read the repository root `.env`:

```bash
EVENTSALES_DEPLOY_ENV_FILE=/etc/eventsales/eventsales.env \
  docker compose --env-file /dev/null up -d --build
```

The repository does not manage the workstation shared infrastructure through
Compose.

`scripts/dev_postgres.sh` is deprecated for normal EventSales development.
Its old container and volume are retained while the migration is verified;
normal development uses `bash scripts/dev_local.sh`. Its `reset` command is
disabled and `stop` retains the legacy container and volume.
