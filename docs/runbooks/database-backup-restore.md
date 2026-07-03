# Database Backup and Restore

## Purpose

Prove EventSales can recover Postgres durable truth before live cutover.

## Railway production backup

1. Open the Railway project for EventSales.
2. Select the PostgreSQL service.
3. Create a manual backup/snapshot before cutover or risky migrations.
4. Record the backup timestamp in the launch checklist.
5. Do not store connection strings or credentials in tickets, chat, or evidence artifacts.

## Local proof path

Run the repository verification script from a machine with Postgres client tools installed:

```bash
bash scripts/verify_backup_restore.sh
```

The script:

1. Dumps the local test database with `pg_dump`
2. Restores into a temporary database
3. Runs `mix ecto.migrate` against the restored database
4. Executes a minimal read query
5. Prints only `backup_restore_proof: passed` or `backup_restore_proof: failed`

## Restore guidance

1. Stop application traffic or disable live webhook cutover first.
2. Restore Postgres from the chosen Railway backup or local dump.
3. Confirm migration version compatibility before activating a release.
4. Run production smoke and cutover dry run after restore.
5. Run reconciliation for the outage gap window.

## Related docs

- [`migrations-and-release.md`](../deployment/migrations-and-release.md)
- [`live-webhook-cutover.md`](live-webhook-cutover.md)
