# WordPress integration health (WP-SOURCE-02 and WP-SOURCE-03)

Read-only observability for EventSales producer plugins on WordPress. No REST health route, no remote probes, no catalogue or order authority.

## Where to look

- **Site Health → Status:** direct tests for catalog feed, catalogue-change sender, order index feed, and order line identity.
- **Tools → Site Health → Info:** section **EventSales integrations** (readiness booleans, contract versions, and sanitized delivery fields).

## Health states

| State | Meaning |
|-------|---------|
| ABSENT | Plugin not installed |
| INACTIVE | Installed but not active |
| DISABLED | Optional sender intentionally off (not a failure) |
| MISCONFIGURED | Active but required local configuration missing |
| DEPENDENCY_UNAVAILABLE | Active but runtime dependency or storage missing |
| READY | Readiness requirements satisfied |

## Secret policy

Health output reports `authentication_configured`, `endpoint_configured`, and similar fields as **true/false** only. Secrets, tokens, endpoints with path tokens, and manifest contents are never included.

## Catalogue-change delivery telemetry

The catalogue-change sender report adds a separate delivery outcome to the
existing readiness report. `READY` means the sender is enabled, configured,
and its Action Scheduler functions are available. The delivery field reports
whether an attempt has run and what happened. A delivery failure does not
change readiness.

The debug section includes `delivery_telemetry_supported`,
`delivery_telemetry_version`, `delivery_state`, the attempt and outcome
timestamps, HTTP status, failure category, and attempt number. If an older
catalogue producer has no telemetry accessor, support is `false` and the
telemetry values are empty. Health does not read the producer option directly.

| Delivery state | Meaning |
|----------------|---------|
| `NEVER_ATTEMPTED` | No delivery outcome is recorded. |
| `RETRY_SCHEDULED` | Action Scheduler returned a positive action ID for the retry. |
| `SUCCEEDED` | The attempt received a 2xx response. |
| `TERMINAL_FAILURE` | The attempt stopped without another retry. |

The producer stores one bounded, non-autoloaded option. It contains no raw
signal body, payload hash, endpoint, path token, key, secret, signature, headers,
response body, WordPress error text, exception details, customer data, order
data, payment data, or ticket-holder data. It keeps no event history. The
success and terminal-failure timestamps describe the attempt in the current
record; they are empty for other states.

Failure categories use a closed vocabulary: `transport_error`,
`retryable_http`, `non_retryable_http`, and `retry_schedule_failed`.
`retry_schedule_failed` means Action Scheduler was unavailable or did not
return a positive integer action ID. Health does not report
`RETRY_SCHEDULED` for a failed scheduling call.

Action Scheduler may run deliveries concurrently. The attempt number belongs
to the recorded attempt, and the option reflects the write that completed last.
Concurrent option writes cannot maintain a truthful global failure counter, so
health does not report one. Retry statuses, the five-attempt limit, and retry
delays remain unchanged.

## Plugin path

```text
integrations/wordpress/eventsales-integration-health/
```

Symlink or copy into the local WordPress `wp-content/plugins/` tree for localhost verification.

## Tests

```bash
php -l integrations/wordpress/eventsales-integration-health/*.php
php integrations/wordpress/eventsales-integration-health/tests/integration-health-test.php
```
