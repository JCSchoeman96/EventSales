# M3-05C3 Webhook Refund Integration Design

## Goal

Integrate the existing `EventSales.Ingestion.OrderRefundSync` service into
accepted WooCommerce `order.created` and `order.updated` webhook processing so
the live path converges durable refund facts and confirmed source deletions
before it notifies downstream hot state or marks the webhook processed.

## Scope and boundaries

Only `EventSales.Ingestion.WebhookProcessor` and its focused tests change.
`ProcessWebhookWorker`, `WebhookEvent`, `OrderRefundSync`, `RefundUpserter`,
Ash resources, migrations, queues, and webhook topics remain unchanged.

The existing classification gates run first and remain authoritative:
unsupported topics, duplicate processed resource hashes, stale events against a
newer processed source version, and already-terminal events do not invoke order
processing or refund synchronization.

## Processing flow

For an accepted order webhook, `WebhookProcessor` preserves this sequence:

```text
OrderUpserter.upsert_from_webhook_event(event)
    |
    +-- {:ok, %Order{}} or {:ok, :stale_noop}
    |
    v
OrderRefundSync.sync_order(event.source_system_id, event.resource_id)
    |
    +-- :ok
    v
OrderProcessedNotifier.notify_order_processed/2 only for %Order{}
    |
    v
WebhookEvent :processed
```

The source order identity passed to C1 is the already durable string
`WebhookEvent.resource_id`; the processor does not parse, duplicate, or
revalidate that identity. C1 remains responsible for its own source/client
safety and positive-ID validation.

An order upsert returning `{:ok, :stale_noop}` still runs C1, because the
parent order can be current while refund membership is not. It does not invoke
the notifier. An order-upsert error returns through the existing upsert error
classifier and does not run C1.

## Error handling

The processor adapts C1's `{:error, reason}` result to the existing webhook
lifecycle without changing the worker contract. These C1 atoms are transient:

```text
:rate_limited
:timeout
:server_error
:queue_timeout
:circuit_open
:transport_error
```

They return `{:error, {:transient, reason}}`, leave the event queued through
the existing `mark_retryable` action, and allow `ProcessWebhookWorker` to retry.

Every other C1 error is permanent for this path. It marks the event failed via
the existing `mark_failed` action and returns `:ok` to the worker, matching the
current webhook behavior for permanent order failures. No new retry policy is
introduced for source-integrity or authorization errors.

The notifier remains after successful refund synchronization. Its existing
failure isolation is preserved, so notifier failure does not prevent the
existing final processed transition after C1 has succeeded.

## Test design

Focused `WebhookProcessor` tests inject a recording refund-sync module through
the existing `:event_sales, :order_refund_sync` application configuration seam.
The recording module captures calls, results, and an ordering trace; it does
not perform WooCommerce HTTP or durable refund writes.

The tests cover:

- both `order.created` and `order.updated` accepted paths;
- successful Order -> refund sync -> notifier -> processed ordering;
- refund sync receiving the event source UUID and exact string resource ID;
- stale-noop Order -> refund sync, with no notifier;
- Order failure -> no refund sync and existing permanent/transient handling;
- each transient C1 reason remaining retryable and queued;
- representative permanent C1 errors failing closed;
- duplicate, stale, and unsupported gates avoiding the refund seam;
- refund failure preventing notification and processed status until retry.

No worker test or worker production change is required because the existing
worker already forwards the processor's transient contract unchanged.

## Verification

Run the focused `WebhookProcessor` suite, compile with warnings as errors, and
run `mix quality.fast` at slice completion. Inspect the final diff for the
allowed narrow file scope and verify that no migration, resource, worker, or
source-boundary change was introduced.
