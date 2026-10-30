# VS-26E.0 Controlled Catalog Dry-Run

## Preconditions

- Pack and plan approved.
- Read-only preflight passed.
- Required migrations/index verified.
- No unexplained active Catalog Sync run.
- No relevant active/retryable Catalog Sync job.
- WordPress feed plugin and EventSales adapter configuration verified.
- Operator is a global admin.
- No concurrent catalog reconciliation/backfill.
- Dry-run phase explicitly approved.

## Feed checks

Verify without secrets:

- feed enabled;
- base host expected;
- plugin active;
- schema version accepted;
- timestamp clocks sufficiently aligned;
- per-page/max-pages/timeout bounded;
- approximately expected event/product scale;
- no raw response retained.

A known product/event targeted probe may be used only when the reviewed plan requires it. It does not replace the full certification dry-run.

## Queue one full public-feed dry-run

Use the existing admin surface `/admin/catalog-sync` and scope equivalent to:

```elixir
%{"kind" => "wordpress_feed", "mode" => "full"}
```

Do not use `include_private` or manual JSON to certify the public baseline.

## Observe durable lifecycle

Record safe fields:

- run id;
- source id or approved alias;
- scope;
- inserted/started/finished timestamps;
- status transitions;
- retry attempt/max;
- bounded `last_error`;
- Oban job state.

Expected success:

```text
queued -> discovering -> dry_run_ready
```

Transient source failures may produce:

```text
discovering -> retry_scheduled -> discovering
```

Terminal failure is evidence, not permission to edit state.

## Preview review

Reload the preview from durable truth and record:

- event change count;
- ticket-type change count;
- product-mapping change count;
- finding count by severity/code;
- historical-impact summary where present;
- plan snapshot present;
- 64-character lower-case SHA-256 dry-run hash;
- source snapshot timestamp;
- representative identity samples without PII.

## Required human review

Review every:

- blocking finding;
- warning/review reason;
- create/adopt/update action;
- product/variation identity;
- unexpected event;
- missing live event;
- subscription/payment-plan/bundle/add-on hint;
- event metadata and dates;
- existing mapping conflict;
- historical impact.

The owner has approximately twenty live/public events. Large unexplained divergence is a stop.

## Outcome

Choose:

- `APPROVE EXACT RUN/HASH FOR APPLY`
- `REVOKE/NO-GO`
- `BLOCKED — CORRECTIVE WORK REQUIRED`

Dry-run success alone never authorises Apply.
