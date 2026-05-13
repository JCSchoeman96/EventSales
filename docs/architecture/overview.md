# EventSales Architecture Overview

Slice `0.4` introduces the Ash ecosystem baseline only. It proves that this repo can compile and run with:

- `ash`
- `ash_postgres`
- `ash_authentication`
- `ash_admin`
- `ash_state_machine`
- `ash_paper_trail`

The proof surface lives under `EventSales.AshBaseline` and is intentionally isolated from the future business domains. It currently contains:

- `EventSales.AshBaseline.Domain`
- `EventSales.AshBaseline.Resources.AuthUser`
- `EventSales.AshBaseline.Resources.StateMachineProof`
- `EventSales.AshBaseline.Resources.PaperTrailProof`

These modules exist only to prove ecosystem readiness against Postgres-backed tests and generated AshPostgres migrations. They are not the long-lived business model.

## Deferred Ownership

Slice `0.4` does **not** implement the real application domains or real auth/admin flows:

- real domain boundaries remain owned by Slice `1.0`
- real authentication remains owned by Slice `2.0`
- real AshAdmin protection remains owned by Slice `2.5`
- real business state machines remain owned by Slices `4.0` and `8.6`
- real PaperTrail rollout remains owned by Slice `8.8`

## AshAdmin Boundary

`AshAdmin` is mounted only as an internal proof tool at `/internal/ash-admin`.

- it is not the product dashboard
- it is not publicly accessible
- it is guarded by `EventSalesWeb.Plugs.InternalOnly`
- it only exposes the isolated `EventSales.AshBaseline` proof domain/resources

All existing architecture boundaries still apply, especially the rule that the dashboard and web layer must not call WooCommerce REST directly.
