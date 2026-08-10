# M3-00 Backfill Start Authority Implementation Plan

> **For agentic workers:** Execute this plan task-by-task with test-first checkpoints. Keep all changes inside the M3-00 boundary.

**Goal:** Persist authoritative Tickera Event creation time from a verified event-scoped catalog snapshot.

**Architecture:** Keep WordPress as the source of `post_date_gmt`, carry the value through the existing feed/normalizer/planner snapshot path, and persist it only through a dedicated immutable Event action invoked by a Postgres-transactional capture service. Extend snapshot validation compatibly so existing M2 snapshots remain certifiable.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres, Ecto/Postgres, Phoenix test support, PHP WordPress feed contract tests.

---

### Task 1: Lock the Event persistence boundary

**Files:**
- Modify: `lib/event_sales/catalog/resources/event.ex`
- Test: `test/event_sales/catalog/event_source_created_at_test.exs`

- [ ] Write tests proving the field is nullable on create, generic `:update` cannot accept it, the capture action stores a timestamp, repeats are idempotent, and a different timestamp fails with `:source_created_at_conflict`.
- [ ] Run `mix test test/event_sales/catalog/event_source_created_at_test.exs` and observe failure because the attribute/action do not exist.
- [ ] Add `source_created_at :utc_datetime_usec`, accept it only on create/capture as required by existing import boundaries, add `update :capture_source_created_at`, and keep generic `:update` unable to accept it.
- [ ] Add the narrow before-action conflict validation and run the focused test until green.

### Task 2: Add source evidence to feed and normalization

**Files:**
- Modify: `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php`
- Modify: `lib/event_sales/catalog/tickera_catalog/catalog_row.ex`
- Modify: `lib/event_sales/catalog/tickera_catalog/normalizer.ex`
- Modify: `test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs`
- Modify: `test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs`
- Modify: `test/event_sales/catalog/tickera_catalog/normalizer_test.exs`
- Modify: `test/support/tickera_catalog_fixtures.ex`
- Modify: `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php`

- [ ] Add failing assertions that `post_date_gmt` and `post_modified_gmt` serialize as separate UTC fields and that native v3 accepts the additive event key.
- [ ] Run the focused PHP and Elixir tests to confirm the new assertions fail.
- [ ] Select/`GROUP BY` `ev.post_date_gmt` in the authoritative event queries, serialize it as `event_source_created_at`, preserve `event_source_updated_at`, and extend `CatalogRow`/normalization with strict parse-to-nil behavior.
- [ ] Run the focused feed/discovery/normalizer tests and retain the unchanged v3 envelope/version assertions.

### Task 3: Carry evidence through deterministic snapshots

**Files:**
- Modify: `lib/event_sales/catalog/tickera_catalog/planner.ex`
- Modify: `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex`
- Modify: `test/event_sales/catalog/tickera_catalog/planner_applier_test.exs`
- Modify: `test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs`

- [ ] Add failing planner assertions for create/adopt/update actions, nil-to-present metadata deltas, matching timestamps, and differing timestamps.
- [ ] Run planner/canonicalizer tests to confirm they fail.
- [ ] Add `source_created_at` to Event plan actions and metadata-delta comparison; allow new snapshots to canonicalize while accepting the legacy action key sets used by prior M2 runs.
- [ ] Run planner and snapshot tests and verify planner does not mutate Events.

### Task 4: Build trusted backfill-start capture

**Files:**
- Create: `lib/event_sales/ingestion/backfill_start_capture.ex`
- Create: `test/event_sales/ingestion/backfill_start_capture_test.exs`

- [ ] Write the required trusted-run, evidence, idempotency, conflict, state-preservation, and no-side-effect tests using exact Event and SyncRun UUIDs.
- [ ] Run the new test file and observe failures for the missing capture module.
- [ ] Implement `capture/2` with an exact Event-row `FOR UPDATE` lock, run binding validation, canonical snapshot hash verification, selected Event evidence extraction, and the dedicated Event capture action inside one `Repo.transaction`.
- [ ] Run the capture test file, then the M2 onboarding and structural-certifier regressions.

### Task 5: Generate schema/index artifacts and project index

**Files:**
- Generated: `priv/repo/migrations/<generated m3_00 migration>.exs`
- Generated: `priv/resource_snapshots/repo/catalog_events/<generated snapshot>.json`
- Generated: `INDEX.md`
- Generated: `docs/architecture/module_manifest.json`
- Generated: `docs/architecture/domain_map.json`

- [ ] Run `mix ash.codegen m3_00_backfill_start_authority` and inspect that the only schema change is nullable `catalog_events.source_created_at` with no default/index and no SyncRun/SyncCursor changes.
- [ ] Run `mix project.index --check`; regenerate canonical outputs with `mix project.index` only if the new public module makes them stale, then rerun the check.

### Task 6: Run the required verification and checkpoint

**Files:**
- Inspect: all changed paths from `git diff --check` and `git diff --stat`

- [ ] Start only loopback Postgres with `docker compose --env-file /dev/null up -d postgres` and verify `docker compose --env-file /dev/null port postgres 5432` reports `127.0.0.1:5432`.
- [ ] Run focused Elixir tests and the existing PHP feed test command.
- [ ] Run `mix quality.fast`, `mix quality.pr`, `mix quality.ci`, `mix hex.audit`, `mix deps.audit`, and `git diff --check`, stopping on any specified failure condition.
- [ ] Stop Postgres with `docker compose --env-file /dev/null stop postgres`.
- [ ] Review that no generic Apply, worker, order, SyncRun schema, or SyncCursor code was added; commit as `Persist authoritative Tickera event creation time` and push the requested branch when verification is complete.
