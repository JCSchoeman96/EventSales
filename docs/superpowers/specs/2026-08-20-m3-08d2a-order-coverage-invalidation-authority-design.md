# M3-08D2A — Order Coverage Invalidation Authority

**Date:** 2026-08-20  
**Baseline:** `6e4fb10d321020b2191430d93ce35498a20e4d85`  
**Status:** Approved design

## Goal

Provide one bounded, auditable service that invalidates only the currently
certified historical coverage certificates whose inclusive sales range
contains a proven-mutated Order.

The caller is responsible for proving that a later Order mutation occurred
and for supplying the small candidate Event ID set. D2A does not discover
affected Events or detect mutations.

## Public boundary

Create `EventSales.Ingestion.HistoricalCoverageInvalidator` with:

```elixir
invalidate_order_change(order, event_ids)
```

The success contract is:

```elixir
{:ok,
 %{
   invalidated_event_ids: [event_id()],
   skipped: [
     %{event_id: event_id(), reason: :no_current_coverage},
     %{event_id: event_id(), reason: :outside_sales_coverage}
   ]
 }}
```

Event IDs in the result are canonical UUID strings. Input IDs are normalized
and deduplicated before processing, preserving the first normalized input
position. An Event can appear at most once across both result collections.

The only skip reasons are:

```elixir
:no_current_coverage
:outside_sales_coverage
```

Unexpected conditions remain errors:

```elixir
{:error, :invalid_order}
{:error, :invalid_event_id}
{:error, :historical_coverage_lookup_failed}
{:error, :coverage_source_mismatch}
{:error, :order_coverage_invalidation_failed}
```

## Processing authority and flow

The service validates the Order and all candidate IDs before making any
invalidation write. It then processes canonical Event IDs sequentially:

```text
validated Order + candidate IDs
|> HistoricalCoverageResolver.resolve_current(event_id)
|> no current certificate: record :no_current_coverage
|> current certificate: compare exact source_system_id
|> source mismatch: return :coverage_source_mismatch
|> compare Order.created_at_source to B..C inclusively
|> outside range: record :outside_sales_coverage
|> inside range: invoke SyncRun :invalidate_order_coverage
|> continue to the next candidate
```

`HistoricalCoverageResolver.resolve_current/1` is the sole current-certificate
read authority. D2A must not query certificate rows directly, search older
certificates after a resolver miss, or scan all Events/certificates.

For a current certificate, the source check is:

```elixir
order.source_system_id == certificate.source_system_id
```

The historical sale membership check is:

```elixir
order.created_at_source >= certificate.coverage_start and
order.created_at_source <= certificate.sales_covered_through
```

Both boundaries are inclusive. The service must not use
`updated_at_source`, `coverage_certified_at`, or
`refunds_covered_through` to decide whether the Order sale belongs to B→C.

## Durable mutation and audit

For an in-scope Order, D2A invokes exactly:

```elixir
Ash.update(
  certificate,
  %{coverage_invalidation_reason: :historical_order_changed},
  action: :invalidate_order_coverage,
  domain: EventSales.Ingestion
)
```

The existing `SyncRun` action remains the mutation authority. It marks both
order and refund coverage incomplete, sets `coverage_invalidated_at`, and
preserves `coverage_start`, `sales_covered_through`,
`refunds_covered_through`, and `coverage_certified_at`. D2A must not delete or
rewrite the certificate.

An invalidation write failure returns
`{:error, :order_coverage_invalidation_failed}`. Processing is fail-fast for
unexpected errors; successful writes for earlier candidates are not undone.
Multi-event transaction orchestration is outside this slice.

After a successful invalidation, a subsequent resolver call must return
`{:error, :historical_coverage_not_current}`. Replaying the same D2A request
therefore produces a deterministic `:no_current_coverage` skip rather than a
second invalidation.

## Focused test design

The D2A test module will prove:

- invalid Orders return `:invalid_order`;
- malformed candidate IDs return `:invalid_event_id` before any write;
- duplicate IDs are normalized/deduplicated in deterministic input order;
- an Event without current coverage is skipped with
  `:no_current_coverage`;
- Orders before B and after C are skipped with
  `:outside_sales_coverage`;
- Orders exactly at B and exactly at C are invalidated;
- membership uses `created_at_source`, not `updated_at_source`;
- membership does not depend on certification time or refund coverage end;
- a source mismatch returns `:coverage_source_mismatch` and is not skipped;
- an in-scope Event is invalidated with reason
  `:historical_order_changed`;
- all original certificate boundaries and certification audit data remain;
- the resolver reports the invalidated certificate as not current;
- replay after invalidation is an explicit `:no_current_coverage` skip;
- resolver lookup errors and invalidation write errors remain errors rather
  than becoming skips.

## Explicitly out of scope

D2A does not change or implement:

- OrderUpserter or WebhookProcessor integration;
- mutation detection, before/after snapshots, OrderItem diffing, or Event-ID
  discovery;
- refund invalidation;
- historical workers or multi-event transaction orchestration;
- new resources, tables, migrations, or indexes;
- Redis, ETS, Cachex, HTTP, Oban, PubSub, or external services;
- financial reconciliation, `ANALYTICS_READY`, M4, M5, or Path 2.

