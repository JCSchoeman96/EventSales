# M3-00 Backfill Start Authority Design

## Goal

Persist the authoritative Tickera Event creation instant needed by later historical backfill work, using `tc_events.post_date_gmt` from an exact event-scoped certified WordPress feed run.

## Boundaries

This slice adds only the nullable `Event.source_created_at` attribute, its narrow immutable capture action, the feed-to-planner evidence path, and `EventSales.Ingestion.BackfillStartCapture`. It does not create historical SyncRuns, change SyncCursor behavior, apply catalog plans, enqueue workers, or ingest orders.

## Data flow

The WordPress feed emits `event_source_created_at` from `ev.post_date_gmt` and continues emitting `event_source_updated_at` from `ev.post_modified_gmt`. The response parser accepts the additive event metadata under the unchanged native v3 envelope. The normalizer stores the value on `CatalogRow`; the planner includes it in create/adopt/update Event actions; the snapshot canonicalizer validates the new action field while still accepting old M2 snapshots. The capture service verifies the exact Event/run binding and canonical snapshot hash before invoking the dedicated Event capture action.

## Safety and errors

The capture service locks the exact Event row in Postgres, validates `backfill_pending`, `dry_run_ready`, SourceSystem ownership, exact `wordpress_feed` event scope, snapshot presence/hash, and one matching non-nil UTC source-created value. Missing, malformed, foreign, ambiguous, conflicting, or stale evidence fails closed. A matching persisted value is idempotent; a different persisted value returns `:source_created_at_conflict`. No onboarding, catalog structure, sales data, or Oban state changes.

## Validation

Focused tests cover feed serialization and additive v3 parsing, discovery preservation, normalization, planner snapshot evidence, Event action immutability, and all required capture rejection/idempotency cases. The slice then runs generated Ash migration/snapshots, project-index validation, the required quality gates, audits, PHP feed tests, and diff inspection.
