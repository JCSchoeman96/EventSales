# Telemetry

Slice `0.8` establishes EventSales telemetry names and metric definitions before
webhook ingestion, REST reconciliation, Oban workers, and hot dashboard state
become complicated. The application depends only on `:telemetry`,
`telemetry_metrics`, and `telemetry_poller`; no external metrics SaaS or reporter
is required for this foundation.

## Metric Definition Ownership

- `EventSales.Telemetry` owns custom EventSales event names and the thin
  `emit/3` wrapper around `:telemetry.execute/3`.
- `EventSalesWeb.Telemetry` remains supervised by `EventSales.Application` and
  owns `Telemetry.Metrics` definitions.
- Later slices emit these events from their owning boundaries. Slice `0.8` does
  not implement webhook intake, REST calls, Oban workers, cache writes, or
  HotStateAggregator behavior.

## Custom Event Catalog

| Event | Measurements | Low-cardinality metadata | Purpose |
|---|---|---|---|
| `[:event_sales, :webhook, :accepted]` | `%{count: 1}` | `:topic`, `:source` | Count accepted WooCommerce webhooks after durable acceptance. |
| `[:event_sales, :webhook, :rejected]` | `%{count: 1}` | `:topic`, `:reason`, `:source` | Count rejected webhook attempts without storing unsafe payloads. |
| `[:event_sales, :rest, :request, :stop]` | `%{duration: native_time}` | `:operation`, `:status`, `:source` | Measure successful WooCommerce REST request latency. |
| `[:event_sales, :rest, :request, :exception]` | `%{count: 1, duration: native_time}` | `:operation`, `:reason`, `:source` | Count REST failures and preserve failure duration when available. |
| `[:event_sales, :hot_state, :rebuild, :start]` | `%{count: 1}` | `:source` | Count HotStateAggregator rebuild attempts. |
| `[:event_sales, :hot_state, :rebuild, :stop]` | `%{duration: native_time}` | `:result`, `:source` | Measure completed HotStateAggregator rebuilds. |
| `[:event_sales, :hot_state, :rebuild, :exception]` | `%{count: 1}` | `:reason`, `:source` | Count failed HotStateAggregator rebuilds. |

Keep metadata bounded and low-cardinality. Do not include secrets, raw webhook
payloads, authorization headers, cookies, customer PII, or unbounded error
messages in telemetry metadata.

## Oban Metrics

Oban emits its own telemetry events. EventSales defines metrics for the baseline
events used by Oban 2.x:

| Event | Measurement | Purpose |
|---|---|---|
| `[:oban, :supervisor, :init]` | `:system_time` | Confirm Oban supervisor initialization is visible. |
| `[:oban, :job, :start]` | `:system_time` | Count job starts by queue and worker where metadata is present. |
| `[:oban, :job, :stop]` | `:duration` | Measure successful job execution duration. |
| `[:oban, :job, :exception]` | `:duration` | Count failed jobs by queue and worker where metadata is present. |

Slice `5.7` owns production-like Oban/PgBouncer behavior. Slice `0.8` only makes
the metrics contract visible.

## Future Emission Points

- Webhook accepted/rejected events are emitted by Slice `5.0` and hardened by
  Slices `5.1` and `5.5`.
- REST request stop/exception events are emitted by the worker-only
  WooCommerce REST boundary in Slice `7.5`.
- HotStateAggregator rebuild events are emitted by Slices `9.5` and `9.6`.
- Cache hit/miss, CSV import, reconciliation, replay, and maintenance events can
  be added in their owning slices using the same `EventSales.Telemetry` pattern.
