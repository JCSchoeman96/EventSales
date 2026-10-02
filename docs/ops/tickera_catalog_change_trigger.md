# Tickera Catalog Change Trigger

The WordPress plugin emits asynchronous, signed, PII-free change notifications to
`POST /webhooks/catalog-change/:path_token`. EventSales stores immutable receipts,
coalesces exact event/product/variation targets, and queues existing Catalog Sync
dry-runs. It never generates full or `updated_since` scopes and never auto-Applies.

Both sender and receiver are disabled by default. Use a dedicated trigger secret;
never reuse the signed GET-feed or WooCommerce webhook credentials. Permanent
deletion remains an operator warning because the current feed has no tombstones.

## Delivery telemetry (WP-SOURCE-03)

The catalogue producer stores one current delivery record in the non-autoloaded
WordPress option `eventsales_catalog_change_delivery_telemetry`. It records an
asynchronous sender outcome after an HTTP attempt. It does not record readiness,
delivery history, request or response content, error text, endpoint details, or
credentials. The telemetry version is independent of the catalogue feed
contract versions.

The delivery states are:

| State | Meaning |
|-------|---------|
| `NEVER_ATTEMPTED` | No valid delivery outcome has been recorded. |
| `RETRY_SCHEDULED` | A retryable response or transport error occurred and Action Scheduler received the existing retry action. |
| `SUCCEEDED` | The recorded attempt received a 2xx response. |
| `TERMINAL_FAILURE` | The attempt received a non-retryable response, exhausted attempt 5, or could not schedule a retry. |

Failure categories are `transport_error`, `retryable_http`,
`non_retryable_http`, and `retry_scheduler_unavailable`. Status `0` means the
transport returned a WordPress error. The category contains no error message.

Retryable statuses remain `0`, `408`, `425`, `429`, and `5xx`. The sender keeps
its maximum of five attempts and delays of 30, 120, 600, and 1800 seconds. The
telemetry does not change retry arguments or add another retry path.

Integration Health readiness and delivery state answer different questions.
`READY` means the sender is configured and its scheduler functions exist. It
does not mean a delivery has succeeded. `NEVER_ATTEMPTED` means no outcome is
recorded, `RETRY_SCHEDULED` means the latest stored outcome requested a retry,
and `TERMINAL_FAILURE` means that attempt stopped without another retry.

Action Scheduler can run deliveries concurrently. Each record describes one
completed attempt, and its attempt number belongs to that attempt. WordPress
option writes do not provide an atomic global failure count, so no such counter
is stored. Overlapping deliveries can write their results out of chronological
start order. The option keeps only the outcome whose write completed last; it is
not a history or a globally ordered delivery timeline.
