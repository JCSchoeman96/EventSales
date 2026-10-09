# EventSales Dev Core contract

This tracked directory records the non-secret workstation allocation. The Dockge-owned `dev-core` stack remains the lifecycle owner.

The allocation uses PostgreSQL DEV at `127.0.0.1:55432` with role/database `eventsales_dev`/`event_sales_dev`, and PostgreSQL TEST at `127.0.0.1:55433` with `eventsales_test`/`event_sales_test`. TEST has `CREATEDB` because `scripts/dev_local.sh test` creates isolated run and partition databases.

Redis DEV and TEST use `127.0.0.1:56379` and `127.0.0.1:56380`. The bootstrap checks the `eventsales:dev` and `eventsales:test` prefixes. Application Redis keys keep the matching environment namespace. ExUnit uses in-memory Redis adapters; bootstrap checks write only short-lived keys inside those prefixes.

`~/.config/dev-core/project-db.env` is the password authority. `.env.local` is a generated, ignored copy with mode `0600`. Do not copy passwords between worktrees or edit the generated database keys by hand.

For a fresh worktree, run:

```bash
devcore-project plan
devcore-project activate
```

The local runtime script performs those commands before starting, migrating, testing, or running quality checks. It runs Mix commands through the matching `devcore-project run dev` or `devcore-project run test` profile.
