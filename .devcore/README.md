# EventSales local infrastructure contract

This tracked configuration allocates EventSales roles and databases on the shared
workstation `dev-core` PostgreSQL clusters. Passwords stay in
`~/.config/dev-core/project-db.env`; `.env.local` is a generated, ignored copy.

After creating a worktree or changing this contract, run:

```bash
devcore-project plan
devcore-project activate
```

Activation provisions only the EventSales roles and databases, renders
`.env.local` with mode `0600`, and checks the project Redis namespace. It does
not manage the shared service lifecycle or run application migrations.
