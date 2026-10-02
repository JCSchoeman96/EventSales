# WP-SOURCE-03 — Catalogue-change sender delivery telemetry

**Plan ID:** wp-catalog-sender-telemetry
**Plan version:** v1
**Status:** active
**Issue:** JC-313
**Base:** `4404865dc7f29ab6922853253f57d171f6698d36` (`origin/main` when this worktree was created)

## Goal

Persist one bounded, sanitized record of a catalogue-change delivery outcome and expose it through the existing read-only WordPress integration health snapshot.

## Current sender flow

The producer coalesces catalogue targets in memory during WordPress callbacks. At `shutdown`, `flush_catalog_changes()` checks that the sender is enabled and that `as_enqueue_async_action()` exists. It creates a PII-free signal body, enqueues `eventsales_catalog_change_deliver` with `raw_body` and attempt `1`, then clears the in-memory targets. If the enqueue function is absent, it writes the existing fixed error token to the PHP error log and returns.

The Action Scheduler callback `deliver_catalog_change($raw_body, $attempt)` returns without a delivery attempt when sending is disabled or endpoint, key ID, or secret configuration is incomplete. Otherwise it signs the original body and calls `wp_remote_post()` with the existing five-second timeout. A `WP_Error` maps to status `0`; otherwise the response code is cast to an integer. Status `0`, `408`, `425`, `429`, and all statuses `>= 500` are retryable. For attempts below `5`, the callback schedules the same hook and group with the unchanged raw body and attempt incremented by one, using delays of `30`, `120`, `600`, and `1800` seconds for attempts `1` through `4`. There is no attempt-six path. Other responses receive no retry.

The telemetry write belongs after the asynchronous HTTP attempt and retry decision. No telemetry write belongs in `flush_catalog_changes()` or a catalogue save/invalidation callback.

## Locked outcome branches

| Delivery result | Persisted state | Failure category | Retry behavior |
|---|---|---|---|
| 2xx | `SUCCEEDED` | `null` | No retry |
| Retryable status, attempt below 5, retry scheduler returns a positive action ID | `RETRY_SCHEDULED` | `transport_error` for status 0; otherwise `retryable_http` | Existing retry call and arguments |
| Retryable status, attempt below 5, retry scheduler function absent or returns no positive action ID | `TERMINAL_FAILURE` | `retry_schedule_failed` | No alternate retry |
| Retryable status, attempt 5 | `TERMINAL_FAILURE` | `transport_error` for status 0; otherwise `retryable_http` | No retry |
| Other non-2xx status | `TERMINAL_FAILURE` | `non_retryable_http` | No retry |

The closed delivery-state vocabulary is `NEVER_ATTEMPTED`, `RETRY_SCHEDULED`, `SUCCEEDED`, and `TERMINAL_FAILURE`. The closed failure-category vocabulary is `transport_error`, `retryable_http`, `non_retryable_http`, and `retry_schedule_failed`. `RETRY_SCHEDULED` requires a positive integer action ID from `as_schedule_single_action()`. The API returns zero when it cannot schedule an action, so an unavailable function or a non-positive/non-integer result records terminal failure. Configuration-disabled or incomplete calls do not create an attempt record.

## Storage and producer read contract

The producer owns the single option `eventsales_catalog_change_delivery_telemetry`. Every write uses `update_option('eventsales_catalog_change_delivery_telemetry', $record, false)`. The record has exactly these eight keys:

```text
telemetry_version
state
last_attempt_at_gmt
last_success_at_gmt
last_terminal_failure_at_gmt
last_http_status
last_failure_category
last_attempt_number
```

`EVENTSALES_CATALOG_CHANGE_TELEMETRY_VERSION` identifies this operational record independently of all feed contract constants. Its value is `2026-10-02.v1`. Times use `gmdate('Y-m-d\\TH:i:s\\Z')`. A `WP_Error` records status `0`, never its message. HTTP status is an integer. Attempt number is the bounded integer from the current Action Scheduler arguments, in the supported range `1..5`.

The record describes one completed attempt. `last_success_at_gmt` is set to that attempt's timestamp only for `SUCCEEDED`; `last_terminal_failure_at_gmt` is set only for `TERMINAL_FAILURE`. Both are null for other states. This avoids carrying an outcome forward through a concurrent read/modify/write. Success clears the failure category. The accessor returns a deterministic `NEVER_ATTEMPTED` record when no valid state exists, validates state, category, time, status, and attempt values, and returns only the eight fixed keys. It does not write.

The public producer API is `EventSales_Tickera_Catalog_Feed::catalog_change_delivery_telemetry(): array`. Health calls this accessor only when the method exists. It does not parse the producer option itself.

## Concurrency decision

Action Scheduler can run catalogue-change actions concurrently. WordPress option updates are last-writer-wins and do not provide an atomic shared counter. The stored state therefore describes the delivery attempt whose option update last completed, not a guaranteed chronological maximum across overlapping starts. The attempt number belongs to that attempt.

No global or consecutive failure counter will be added. Such a counter could lose increments or reset incorrectly when concurrent callbacks overwrite one another, so it could not be described as truthful. The record contains no delivery history or payload-derived identity.

## Integration Health compatibility

The existing readiness states and guards remain unchanged. The sender report adds `delivery_telemetry_supported`, `delivery_telemetry_version`, `delivery_state`, `last_attempt_at_gmt`, `last_success_at_gmt`, `last_terminal_failure_at_gmt`, `last_http_status`, `last_failure_category`, and `last_attempt_number`. If the active producer lacks the accessor, support is `false` and telemetry values are null. This does not change readiness. Health remains read-only and makes no network calls.

## Redaction and compatibility boundaries

The option never stores a body, signal or source IDs, endpoint or path, key ID, credentials, signature, headers, response body, WordPress error text, exception details, or customer, order, payment, and ticket-holder data. It stores no payload hash. Health output contains only validated telemetry values and booleans. Save callbacks remain free of HTTP and telemetry writes.

The schema identity remains `2026-08-07.v3`, canonical contract identity remains `source_risk.v3`, and producer identity remains `2026-08-07.1`. Operational telemetry has its own version constant and does not alter Phoenix native-v3 compatibility.

## Focused validation

The producer trigger test will cover the default state, 2xx, retryable HTTP, transport error, retry exhaustion, non-retryable HTTP, missing retry scheduler, scheduler return value zero, positive action IDs, exact record keys, non-autoload writes, retry body preservation, redaction, and unchanged feed constants. The Integration Health test will cover old producers without the accessor, sanitized supported states and failure categories, unchanged readiness, output redaction, and read-only/no-network evaluation.
