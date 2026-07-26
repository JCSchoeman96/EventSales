# Tickera Catalog Conservative Auto-Apply

VS-26E.2 adds a fail-closed automation layer around the existing Tickera catalog dry-run and Apply path. `EventSales.Catalog.TickeraCatalog.Applier` remains the sole writer of Event, TicketType, and ProductMapping records.

## Durable flow

```text
WordPress feed v2
→ DiscoveryResult and CatalogRow source-risk facts
→ Normalizer findings
→ closed tickera_catalog_plan.v2 snapshot
→ deterministic canonical bytes and external dry_run_hash
→ pure AutoApplyPolicy
→ TickeraCatalogAutoApplyDecision
→ atomic decision claim + Oban insert + job linkage
→ existing Apply worker and Applier
```

Postgres owns configuration, decision, enqueue, and Apply-audit truth. Oban provides bounded execution. PubSub only notifies the admin UI after durable state changes; caches and process-local state are not correctness authorities.

## Initial policy

Policy `conservative_auto_apply.v1` is whole-run only. It requires the targeted-catalog-change origin, the v2 snapshot, complete safe source proof, an empty finding set, zero historical impact, supported versions, and enabled configuration. Event metadata updates, adoption, variations, non-create mapping actions, missing risk, unknown semantics, and legacy snapshots remain Human Apply only.

`plan_snapshot` is the exact closed eleven-key v2 object. Its SHA-256 digest is stored separately on the run, decision, and automatic job arguments. Automatic claim requires all three hashes and the recomputed snapshot digest to agree.

## Concurrency

Decision identity and enqueue identity are database-unique. The initial decision claim, Oban insertion, and job linkage commit in one `Ecto.Multi`. Recovery retains the linked job ID, uses bounded exponential delay and `Oban.retry_job/1`, processes at most 100 locked rows, and terminates at attempt 20. Human Apply and cancellation retain the existing atomic run claim.

## Safe defaults

- `CATALOG_AUTO_APPLY_HARD_ENABLED=false`
- durable global mode `disabled`
- source mode `inherit`
- source allowlist false
- enabled policy versions empty

Compilation and migration cannot activate automation.
