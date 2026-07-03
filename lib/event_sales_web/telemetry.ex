defmodule EventSalesWeb.Telemetry do
  @moduledoc """
  Supervised telemetry metrics for Phoenix and EventSales operational events.
  """

  use Supervisor
  import Telemetry.Metrics

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  @spec init(term()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("event_sales.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("event_sales.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("event_sales.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("event_sales.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("event_sales.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # EventSales Operational Metrics
      counter("event_sales.webhook.accepted.count",
        event_name: EventSales.Telemetry.webhook_accepted(),
        measurement: :count,
        tags: [:topic, :source],
        description: "Accepted WooCommerce webhooks"
      ),
      counter("event_sales.webhook.rejected.count",
        event_name: EventSales.Telemetry.webhook_rejected(),
        measurement: :count,
        tags: [:topic, :reason, :source],
        description: "Rejected WooCommerce webhooks"
      ),
      counter("event_sales.webhook.backpressure.count",
        event_name: EventSales.Telemetry.webhook_backpressure(),
        measurement: :count,
        tags: [:reason, :adapter],
        description: "Webhook intake backpressure signals"
      ),
      counter("event_sales.webhook.buffered.count",
        event_name: EventSales.Telemetry.webhook_buffered(),
        measurement: :count,
        tags: [:adapter, :accepted_via],
        description: "Webhooks accepted into degraded-mode buffer"
      ),
      counter("event_sales.webhook.drained.count",
        event_name: EventSales.Telemetry.webhook_drained(),
        measurement: :count,
        tags: [:adapter, :accepted_via],
        description: "Buffered webhooks drained to Postgres"
      ),
      counter("event_sales.webhook.rate_limited.count",
        event_name: EventSales.Telemetry.webhook_rate_limited(),
        measurement: :count,
        tags: [:layer, :token_presence],
        description: "Webhook intake HTTP rate limit rejections"
      ),
      summary("event_sales.rest.request.stop.duration",
        event_name: EventSales.Telemetry.rest_request_stop(),
        measurement: :duration,
        tags: [:operation, :status, :source],
        unit: {:native, :millisecond},
        description: "WooCommerce REST request duration"
      ),
      counter("event_sales.rest.request.exception.count",
        event_name: EventSales.Telemetry.rest_request_exception(),
        measurement: :count,
        tags: [:operation, :reason, :source],
        description: "WooCommerce REST request failures"
      ),
      counter("event_sales.hot_state.rebuild.start.count",
        event_name: EventSales.Telemetry.hot_state_rebuild_start(),
        measurement: :count,
        tags: [:source],
        description: "HotStateAggregator rebuild starts"
      ),
      summary("event_sales.hot_state.rebuild.stop.duration",
        event_name: EventSales.Telemetry.hot_state_rebuild_stop(),
        measurement: :duration,
        tags: [:result, :source],
        unit: {:native, :millisecond},
        description: "HotStateAggregator rebuild duration"
      ),
      counter("event_sales.hot_state.rebuild.exception.count",
        event_name: EventSales.Telemetry.hot_state_rebuild_exception(),
        measurement: :count,
        tags: [:reason, :source],
        description: "HotStateAggregator rebuild failures"
      ),
      counter("event_sales.hot_state.event.applied.count",
        event_name: EventSales.Telemetry.hot_state_event_applied(),
        measurement: :count,
        tags: [:reason, :result, :source],
        description: "HotStateAggregator applied recompute events"
      ),
      counter("event_sales.hot_state.event.ignored.count",
        event_name: EventSales.Telemetry.hot_state_event_ignored(),
        measurement: :count,
        tags: [:reason, :result, :source],
        description: "HotStateAggregator ignored or failed recompute events"
      ),
      counter("event_sales.hot_state.snapshot.write.count",
        event_name: EventSales.Telemetry.hot_state_snapshot_write(),
        measurement: :count,
        tags: [:reason, :result, :source],
        description: "HotStateAggregator warm snapshot writes"
      ),
      counter("event_sales.cache.invalidate.count",
        event_name: EventSales.Telemetry.cache_invalidate(),
        measurement: :count,
        tags: [:scope, :reason, :source],
        description: "Event-scoped dashboard cache invalidations"
      ),
      counter("event_sales.catalog.product_metadata.update.count",
        event_name: EventSales.Telemetry.product_metadata_update(),
        measurement: :count,
        tags: [:result, :source],
        description: "WooCommerce product.updated metadata handling results"
      ),
      counter("event_sales.snapshots.refresh.start.count",
        event_name: EventSales.Telemetry.snapshot_refresh_start(),
        measurement: :count,
        tags: [:scope, :source],
        description: "Historical reporting snapshot refresh starts"
      ),
      summary("event_sales.snapshots.refresh.stop.duration",
        event_name: EventSales.Telemetry.snapshot_refresh_stop(),
        measurement: :duration,
        tags: [:result, :scope, :source],
        unit: {:native, :millisecond},
        description: "Historical reporting snapshot refresh duration"
      ),
      counter("event_sales.snapshots.refresh.exception.count",
        event_name: EventSales.Telemetry.snapshot_refresh_exception(),
        measurement: :count,
        tags: [:reason, :scope, :source],
        description: "Historical reporting snapshot refresh failures"
      ),
      counter("event_sales.reconciliation.start.count",
        event_name: EventSales.Telemetry.reconciliation_start(),
        measurement: :count,
        tags: [:sync_mode, :requested_via, :source],
        description: "Scoped order reconciliation starts"
      ),
      counter("event_sales.reconciliation.stop.count",
        event_name: EventSales.Telemetry.reconciliation_stop(),
        measurement: :count,
        tags: [:sync_mode, :requested_via, :result, :source],
        description: "Scoped order reconciliation step completions"
      ),
      counter("event_sales.reconciliation.exception.count",
        event_name: EventSales.Telemetry.reconciliation_exception(),
        measurement: :count,
        tags: [:sync_mode, :requested_via, :reason, :source],
        description: "Scoped order reconciliation failures"
      ),
      counter("event_sales.reconciliation.pause.count",
        event_name: EventSales.Telemetry.reconciliation_pause(),
        measurement: :count,
        tags: [:sync_mode, :requested_via, :pause_reason, :source],
        description: "Scoped order reconciliation pauses"
      ),
      summary("event_sales.tickera.request.stop.duration",
        event_name: EventSales.Telemetry.tickera_request_stop(),
        measurement: :duration,
        tags: [:operation, :endpoint, :page, :per_page, :status, :source],
        unit: {:native, :millisecond},
        description: "Tickera attendee API request duration"
      ),
      counter("event_sales.tickera.request.exception.count",
        event_name: EventSales.Telemetry.tickera_request_exception(),
        measurement: :count,
        tags: [:operation, :endpoint, :page, :per_page, :reason, :retryable?, :status, :source],
        description: "Tickera attendee API request failures"
      ),
      counter("event_sales.tickera.sync.start.count",
        event_name: EventSales.Telemetry.tickera_sync_start(),
        measurement: :count,
        tags: [:source],
        description: "Tickera attendee sync step starts"
      ),
      counter("event_sales.tickera.sync.stop.count",
        event_name: EventSales.Telemetry.tickera_sync_stop(),
        measurement: :count,
        tags: [:result, :pause_reason, :error_reason, :source],
        description: "Tickera attendee sync step completions"
      ),
      counter("event_sales.tickera.sync.exception.count",
        event_name: EventSales.Telemetry.tickera_sync_exception(),
        measurement: :count,
        tags: [:error_reason, :source],
        description: "Tickera attendee sync unexpected failures"
      ),
      summary("event_sales.maintenance.raw_payload_purge.stop.duration",
        event_name: EventSales.Telemetry.maintenance_raw_payload_purge_stop(),
        measurement: :duration,
        tags: [:worker, :reason],
        unit: {:native, :millisecond},
        description: "Raw webhook payload purge duration"
      ),
      counter("event_sales.maintenance.raw_payload_purge.exception.count",
        event_name: EventSales.Telemetry.maintenance_raw_payload_purge_exception(),
        measurement: :count,
        tags: [:worker, :reason],
        description: "Raw webhook payload purge failures"
      ),
      summary("event_sales.maintenance.stale_sync_cleanup.stop.duration",
        event_name: EventSales.Telemetry.maintenance_stale_sync_cleanup_stop(),
        measurement: :duration,
        tags: [:worker, :reason],
        unit: {:native, :millisecond},
        description: "Stale sync cleanup duration"
      ),
      counter("event_sales.maintenance.stale_sync_cleanup.exception.count",
        event_name: EventSales.Telemetry.maintenance_stale_sync_cleanup_exception(),
        measurement: :count,
        tags: [:worker, :reason],
        description: "Stale sync cleanup failures"
      ),
      counter("event_sales.maintenance.cache_cleanup.stop.count",
        event_name: EventSales.Telemetry.maintenance_cache_cleanup_stop(),
        measurement: :count,
        tags: [:worker, :reason],
        description: "Cache cleanup completions"
      ),
      counter("event_sales.maintenance.failed_job_alert.stop.count",
        event_name: EventSales.Telemetry.maintenance_failed_job_alert_stop(),
        measurement: :count,
        tags: [:worker, :reason],
        description: "Failed Oban job alert checks"
      ),
      counter("event_sales.maintenance.failed_job_alert.exception.count",
        event_name: EventSales.Telemetry.maintenance_failed_job_alert_exception(),
        measurement: :count,
        tags: [:worker, :reason],
        description: "Failed Oban job alert check failures"
      ),
      last_value("event_sales.oban.queue_snapshot.count",
        event_name: EventSales.Telemetry.oban_queue_snapshot(),
        measurement: :count,
        tags: [:queue, :state],
        description: "Grouped Oban queue depth snapshots"
      ),

      # Oban Metrics
      last_value("oban.supervisor.init.system_time",
        event_name: [:oban, :supervisor, :init],
        measurement: :system_time,
        unit: {:native, :millisecond},
        description: "Oban supervisor initialization time"
      ),
      counter("oban.job.start.system_time",
        event_name: [:oban, :job, :start],
        measurement: :system_time,
        tags: [:queue, :worker],
        description: "Started Oban jobs"
      ),
      summary("oban.job.stop.duration",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        tags: [:queue, :worker],
        unit: {:native, :millisecond},
        description: "Successful Oban job duration"
      ),
      counter("oban.job.exception.duration",
        event_name: [:oban, :job, :exception],
        measurement: :duration,
        tags: [:queue, :worker],
        description: "Failed Oban jobs"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EventSalesWeb, :count_users, []}
    ]
  end
end
