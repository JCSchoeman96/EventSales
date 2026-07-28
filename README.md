# EventSales

## Local development

```bash
bash scripts/dev_local.sh
```

This verifies local WordPress, starts PostgreSQL and Redis through Docker Compose,
applies database migrations, and starts native Phoenix at
[`127.0.0.1:4001`](http://127.0.0.1:4001).

Operational commands:

```bash
bash scripts/dev_local.sh status
bash scripts/dev_local.sh doctor
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

`Ctrl+C` stops Phoenix. PostgreSQL and Redis remain available for a quick
restart. Run `bash scripts/dev_local.sh stop` to stop the Compose services.
The script loads only `.env.local` and never sources the root `.env`.

`scripts/dev_postgres.sh` is deprecated for normal EventSales development.
Use `bash scripts/dev_local.sh`.
