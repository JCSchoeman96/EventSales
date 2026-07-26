# VS-26E.2 Implementation Evidence

## Authority and review target

- JC-129 baseline: `8610dd882aa7ea0d1a215e9f9abbea0d5303bed1`
- Approved plan SHA-256: `12a6145d96abdeb4bc6e141396572f1050fae58fe95bcf3de37fab65c33efb2a`
- Approved pack SHA-256: `4b1b5cc428049690da929c30f755abf85b945f23d974ce78a50059e81e23ef30`
- Activation supplement SHA-256: `61885c2bd4161bc151cef449a02e059adb081179ff9cf34cefcf1692b6a35589`
- Previous reviewed head: `6d0e1e8c8b497a828952250eb9e6564383a4b4b3`
- Correction branch: `feat/vs-26e2-conservative-catalog-auto-apply`
- Corrected implementation head before this evidence-only commit: `3f93292f63785c84334942a93833ac9448553e40`

## Correction commits

| Commit | Contract |
|---|---|
| `7ef5236` | Recursive closed snapshot schema, semantic collection sorting, and complete persisted source-risk proof |
| `ab46cf4` | Closed summaries, serialized configuration revisions, enqueue/recovery revalidation, generated migrations and snapshots |
| `3f93292` | Source-scoped cursor decision history and generated architecture indexes |

## File inventory

Created/generated:

- `priv/repo/migrations/20260726144348_vs_26e2_catalog_auto_apply.exs`
- `priv/repo/migrations/20260726144601_vs_26e2_catalog_auto_apply_defaults.exs`
- `priv/resource_snapshots/repo/ingestion_tickera_catalog_auto_apply_decisions/20260726144349.json`
- `priv/resource_snapshots/repo/ingestion_tickera_catalog_auto_apply_decisions/20260726144602.json`

Modified implementation:

- `lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex`
- `lib/event_sales/catalog/tickera_catalog/normalizer.ex`
- `lib/event_sales/catalog/tickera_catalog/planner.ex`
- `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex`
- `lib/event_sales/catalog/tickera_catalog/source_risk.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_auto_apply_decision.ex`
- `lib/event_sales/ingestion/tickera_catalog_auto_apply.ex`
- `lib/event_sales/ingestion/workers/recover_tickera_catalog_auto_apply_worker.ex`
- `lib/event_sales_web/live/admin/catalog_sync_live.ex`

Modified tests:

- `test/event_sales/catalog/tickera_catalog/auto_apply_policy_test.exs`
- `test/event_sales/catalog/tickera_catalog/normalizer_test.exs`
- `test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs`
- `test/event_sales/ingestion/resources/tickera_catalog_auto_apply_config_test.exs`
- `test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs`
- `test/event_sales/ingestion/workers/recover_tickera_catalog_auto_apply_worker_test.exs`

Generated architecture inventory:

- `INDEX.md`
- `docs/architecture/domain_map.json`
- `docs/architecture/module_manifest.json`

## Migration and generated-resource evidence

- Original generated migration remains byte-identical:
  `priv/repo/migrations/20260723065153_vs_26e2_catalog_auto_apply.exs`
  SHA-256 `ad0570ba2111498048890005c8f3634774ef57b54b079c2b0a97c89a25c8e58e`.
- Recovery-index migration:
  `priv/repo/migrations/20260726144348_vs_26e2_catalog_auto_apply.exs`
  SHA-256 `0656f5368a75099302841ddd7ce1daa21e2239d6a50309d21a4c8136ab366d6a`.
- Closed-default/audit-preserving rollback migration:
  `priv/repo/migrations/20260726144601_vs_26e2_catalog_auto_apply_defaults.exs`
  SHA-256 `730b04709e0abaa94a80cacbaaf485c0f0e6496ab9ebb7aa35821cd6736acd82`.
- Latest decision resource snapshot SHA-256:
  `28b7cce8e391e69876d47293a2d494ac43dc4b5202983cd725c4e2a16924b441`.
- `mix ash.codegen --check`: no drift.
- Migrations were executed only against local/test PostgreSQL.

The follow-up migration changes the recovery partial index to the exact due,
nonterminal state set and prevents rollback from reaching the predecessor's
destructive `down`. Operational rollback is code rollback with the hard kill
disabled while additive decision/configuration/audit schema is retained.

## Recursive snapshot and canonical-hash evidence

- The v2 top level remains exactly eleven keys; `dry_run_hash` remains external.
- Exact nested-key validators cover every action variant, findings, risk facts,
  historical destinations, proof objects, and touched product keys.
- Unknown nested keys, missing fields, unsupported enums, invalid nulls and
  floats fail closed.
- Each unordered collection uses its approved persisted-field tuple key rather
  than encoded JSON ordering.
- Permutation tests prove equivalent logical collections produce identical
  canonical bytes and SHA-256.
- The original review reproduction with arbitrary nested keys now returns
  `{:error, :invalid_snapshot_schema}` before policy evaluation.

## Complete source-risk proof evidence

- Normalizer projects explicit safe, risky, missing, unknown and unsupported
  facts through the existing `source_risks` key.
- Product semantic facts are grounded in closed v2 fields; absent is safe,
  present is risky, and missing/unknown stays ineligible.
- No title, slug, description, category or arbitrary metadata-name inference is
  used.
- Policy derives the expected event/product/variation dimension set, rejects
  missing, duplicate and conflicting keys, and permits only a complete
  `explicit_safe` projection.
- An empty proof collection cannot be eligible when actions require proof.
- Legacy feed schemas remain Human-only.

## Closed summaries and privacy evidence

- Action summary: exact six non-negative integer keys, maximum 1,024 bytes.
- Finding summary: exact five non-negative integer keys, maximum 1,024 bytes.
- Historical summary: exact nine non-negative integer keys, maximum 2,048 bytes.
- Application validation rejects unknown, missing, nested, free-form and
  protected-data-shaped keys before persistence.
- Tests reject customer/email/order/payment/card/token/credential/raw-source/
  exception/stacktrace-shaped content.
- PubSub continues to contain only bounded run identity; telemetry labels remain
  fixed and bounded.

## Configuration-concurrency evidence

- The singleton row remains database-enforced as `global`.
- Updates require the expected revision and lock the singleton row.
- Material changes increment once; no-op updates keep the revision.
- Stale revisions return `configuration_revision_conflict`.
- Failed updates roll back configuration and revision together.
- Fingerprints are recomputed from the committed eligibility projection.

## Enqueue atomicity and stale-configuration evidence

The single Ecto.Multi transaction now reloads and checks the decision, run,
singleton configuration and source configuration before job insertion. It
revalidates hard kill, effective mode, allowlist, configuration
revision/fingerprint, origin, policy version, snapshot version, hashes, run
state, eligibility, enqueue state and existing linkage.

Tests prove that a configuration change after evaluation causes
`enqueue_revalidation_failed`, leaves the decision pending, and commits no Oban
job or linkage. Concurrent enqueue still converges on one linked job.

## Recovery and query/index evidence

- Initial linkage schedules bounded reconciliation through `next_attempt_at`.
- Recovery considers only claimed/enqueued/retryable, non-null due rows.
- Query and partial index share the same state and due predicates and ordering.
- Batch size remains 100 with `FOR UPDATE SKIP LOCKED`.
- Active jobs are rescheduled for bounded reconciliation; terminal/completed
  rows clear their due time.
- Same-job retry revalidates current mode, allowlist, revision/fingerprint, run,
  hash, origin, policy/snapshot versions, linkage and Apply audit.
- The linked job ID is retained; no replacement is inserted.
- Attempt 20 remains terminal and attempt 21 is impossible.

Representative non-empty staging EXPLAIN evidence remains a pre-deployment
requirement. Empty local tables may legitimately select sequential scans; no
staging-plan success is claimed here.

## Admin cursor and Human Apply evidence

- Admin history requires `source_system_id`.
- Ordering and cursor are `(inserted_at DESC, id DESC)`.
- Default page size is 25 and the maximum is 100.
- No offset, full-table count or polling is used.
- Duplicate timestamps remain stable through the ID tie-breaker.
- The LiveView exposes only bounded decision/enqueue/audit states and loads the
  next cursor explicitly.
- Existing Human Apply continues to use its original permissions, exact-hash
  claim and Applier path without requiring an auto-Apply decision.
- The existing Applier remains the sole Event, TicketType and ProductMapping
  writer.

## Validation

Focused correction validation:

- Catalog canonicalizer/policy/normalizer/planner suite: 42 tests, 0 failures.
- Auto-Apply/configuration/recovery suite: 12 tests, 0 failures.
- Admin Catalog Sync LiveView suite: 24 tests, 0 failures.
- Expanded affected implementation suite: 87 tests, 0 failures.

Full local CI (`bash scripts/local_ci.sh`):

- ExUnit: 1,095 tests, 0 failures.
- Formatting and warnings-as-errors compilation: pass.
- WooCommerce web boundary: pass.
- Ash codegen drift: none.
- Project architecture index: current.
- Credo strict: no issues.
- Dialyzer: 0 errors.

## Disabled defaults and uncertainties

Hard enable still defaults false, durable global mode defaults disabled,
source mode defaults inherit, source allowlist defaults false, and enabled
policy versions default empty. Observation or enabled behavior cannot be
activated by compilation or migration alone.

Deferred evidence:

- Non-empty staging EXPLAIN for recovery/latest-run/recent-source queries.
- Direct/session-capable shared migration topology verification.
- Shared migration, deployment, observation, WordPress lifecycle and controlled
  canary evidence.

## Prohibited actions

No merge, deployment, shared migration, Railway or WordPress mutation,
shared PostgreSQL/Redis mutation, observation/canary, shared Catalog Sync,
shared Apply, production activity or Linear update was performed.
