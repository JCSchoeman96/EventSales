defmodule EventSales.Telemetry do
  @moduledoc """
  Central contract for EventSales-specific telemetry events.

  This module only names and emits events. Later slices attach the real
  webhook, REST, and hot-state behavior at their owning boundaries.
  """

  @type event_name :: [atom()]
  @type measurements :: %{optional(atom()) => number()}
  @type metadata :: %{optional(atom()) => term()}

  @webhook_accepted [:event_sales, :webhook, :accepted]
  @webhook_rejected [:event_sales, :webhook, :rejected]
  @webhook_backpressure [:event_sales, :webhook, :backpressure]
  @webhook_buffered [:event_sales, :webhook, :buffered]
  @webhook_drained [:event_sales, :webhook, :drained]
  @webhook_replay_audit_failed [:event_sales, :webhook, :replay, :audit_failed]
  @rest_request_stop [:event_sales, :rest, :request, :stop]
  @rest_request_exception [:event_sales, :rest, :request, :exception]
  @hot_state_rebuild_start [:event_sales, :hot_state, :rebuild, :start]
  @hot_state_rebuild_stop [:event_sales, :hot_state, :rebuild, :stop]
  @hot_state_rebuild_exception [:event_sales, :hot_state, :rebuild, :exception]
  @hot_state_event_applied [:event_sales, :hot_state, :event, :applied]
  @hot_state_event_ignored [:event_sales, :hot_state, :event, :ignored]
  @hot_state_snapshot_write [:event_sales, :hot_state, :snapshot, :write]
  @snapshot_refresh_start [:event_sales, :snapshots, :refresh, :start]
  @snapshot_refresh_stop [:event_sales, :snapshots, :refresh, :stop]
  @snapshot_refresh_exception [:event_sales, :snapshots, :refresh, :exception]
  @cache_invalidate [:event_sales, :cache, :invalidate]
  @missing_catalog_recovery_start [:event_sales, :catalog, :missing_catalog, :recovery, :start]
  @missing_catalog_recovery_stop [:event_sales, :catalog, :missing_catalog, :recovery, :stop]
  @missing_catalog_recovery_exception [
    :event_sales,
    :catalog,
    :missing_catalog,
    :recovery,
    :exception
  ]
  @product_metadata_cache_hit [:event_sales, :catalog, :product_metadata_cache, :hit]
  @product_metadata_cache_miss [:event_sales, :catalog, :product_metadata_cache, :miss]
  @product_metadata_cache_put [:event_sales, :catalog, :product_metadata_cache, :put]
  @reconciliation_start [:event_sales, :reconciliation, :start]
  @reconciliation_stop [:event_sales, :reconciliation, :stop]
  @reconciliation_exception [:event_sales, :reconciliation, :exception]
  @reconciliation_pause [:event_sales, :reconciliation, :pause]

  @doc """
  Returns every custom EventSales telemetry event name defined in Slice 0.8.
  """
  @spec event_names() :: [event_name()]
  def event_names do
    [
      webhook_accepted(),
      webhook_rejected(),
      webhook_backpressure(),
      webhook_buffered(),
      webhook_drained(),
      webhook_replay_audit_failed(),
      rest_request_stop(),
      rest_request_exception(),
      hot_state_rebuild_start(),
      hot_state_rebuild_stop(),
      hot_state_rebuild_exception(),
      hot_state_event_applied(),
      hot_state_event_ignored(),
      hot_state_snapshot_write(),
      snapshot_refresh_start(),
      snapshot_refresh_stop(),
      snapshot_refresh_exception(),
      cache_invalidate(),
      missing_catalog_recovery_start(),
      missing_catalog_recovery_stop(),
      missing_catalog_recovery_exception(),
      product_metadata_cache_hit(),
      product_metadata_cache_miss(),
      product_metadata_cache_put(),
      reconciliation_start(),
      reconciliation_stop(),
      reconciliation_exception(),
      reconciliation_pause()
    ]
  end

  @doc "Webhook was durably accepted by the intake boundary."
  @spec webhook_accepted() :: event_name()
  def webhook_accepted, do: @webhook_accepted

  @doc "Webhook was rejected before durable intake."
  @spec webhook_rejected() :: event_name()
  def webhook_rejected, do: @webhook_rejected

  @doc "Webhook intake backpressure (pool saturation, buffer full, etc.)."
  @spec webhook_backpressure() :: event_name()
  def webhook_backpressure, do: @webhook_backpressure

  @doc "Webhook accepted into degraded-mode Redis buffer."
  @spec webhook_buffered() :: event_name()
  def webhook_buffered, do: @webhook_buffered

  @doc "Buffered webhooks drained to Postgres."
  @spec webhook_drained() :: event_name()
  def webhook_drained, do: @webhook_drained

  @doc "Webhook replay was queued but replay audit logging failed."
  @spec webhook_replay_audit_failed() :: event_name()
  def webhook_replay_audit_failed, do: @webhook_replay_audit_failed

  @doc "WooCommerce REST request completed."
  @spec rest_request_stop() :: event_name()
  def rest_request_stop, do: @rest_request_stop

  @doc "WooCommerce REST request failed or raised."
  @spec rest_request_exception() :: event_name()
  def rest_request_exception, do: @rest_request_exception

  @doc "HotStateAggregator rebuild started."
  @spec hot_state_rebuild_start() :: event_name()
  def hot_state_rebuild_start, do: @hot_state_rebuild_start

  @doc "HotStateAggregator rebuild completed."
  @spec hot_state_rebuild_stop() :: event_name()
  def hot_state_rebuild_stop, do: @hot_state_rebuild_stop

  @doc "HotStateAggregator rebuild failed."
  @spec hot_state_rebuild_exception() :: event_name()
  def hot_state_rebuild_exception, do: @hot_state_rebuild_exception

  @doc "HotStateAggregator applied a recompute event."
  @spec hot_state_event_applied() :: event_name()
  def hot_state_event_applied, do: @hot_state_event_applied

  @doc "HotStateAggregator ignored or failed a recompute event."
  @spec hot_state_event_ignored() :: event_name()
  def hot_state_event_ignored, do: @hot_state_event_ignored

  @doc "HotStateAggregator attempted to write a warm snapshot."
  @spec hot_state_snapshot_write() :: event_name()
  def hot_state_snapshot_write, do: @hot_state_snapshot_write

  @doc "Historical reporting snapshot refresh started."
  @spec snapshot_refresh_start() :: event_name()
  def snapshot_refresh_start, do: @snapshot_refresh_start

  @doc "Historical reporting snapshot refresh completed."
  @spec snapshot_refresh_stop() :: event_name()
  def snapshot_refresh_stop, do: @snapshot_refresh_stop

  @doc "Historical reporting snapshot refresh failed."
  @spec snapshot_refresh_exception() :: event_name()
  def snapshot_refresh_exception, do: @snapshot_refresh_exception

  @doc "Cache invalidation signal for an event scope (Slice 3.0 telemetry-only facade)."
  @spec cache_invalidate() :: event_name()
  def cache_invalidate, do: @cache_invalidate

  @doc "Missing catalog recovery started."
  @spec missing_catalog_recovery_start() :: event_name()
  def missing_catalog_recovery_start, do: @missing_catalog_recovery_start

  @doc "Missing catalog recovery completed."
  @spec missing_catalog_recovery_stop() :: event_name()
  def missing_catalog_recovery_stop, do: @missing_catalog_recovery_stop

  @doc "Missing catalog recovery failed or was discarded."
  @spec missing_catalog_recovery_exception() :: event_name()
  def missing_catalog_recovery_exception, do: @missing_catalog_recovery_exception

  @doc "Product metadata cache hit."
  @spec product_metadata_cache_hit() :: event_name()
  def product_metadata_cache_hit, do: @product_metadata_cache_hit

  @doc "Product metadata cache miss."
  @spec product_metadata_cache_miss() :: event_name()
  def product_metadata_cache_miss, do: @product_metadata_cache_miss

  @doc "Product metadata cache write."
  @spec product_metadata_cache_put() :: event_name()
  def product_metadata_cache_put, do: @product_metadata_cache_put

  @doc "Scoped order reconciliation started."
  @spec reconciliation_start() :: event_name()
  def reconciliation_start, do: @reconciliation_start

  @doc "Scoped order reconciliation step completed."
  @spec reconciliation_stop() :: event_name()
  def reconciliation_stop, do: @reconciliation_stop

  @doc "Scoped order reconciliation failed."
  @spec reconciliation_exception() :: event_name()
  def reconciliation_exception, do: @reconciliation_exception

  @doc "Scoped order reconciliation paused for retryable REST errors."
  @spec reconciliation_pause() :: event_name()
  def reconciliation_pause, do: @reconciliation_pause

  @doc "Returns the low-cardinality product metadata cache event for the cache outcome."
  @spec product_metadata_cache_event(:hit | :miss | :put) :: event_name()
  def product_metadata_cache_event(:hit), do: product_metadata_cache_hit()
  def product_metadata_cache_event(:miss), do: product_metadata_cache_miss()
  def product_metadata_cache_event(:put), do: product_metadata_cache_put()

  @doc """
  Emits a telemetry event through the standard `:telemetry` application.
  """
  @spec emit(event_name(), measurements(), metadata()) :: :ok
  def emit(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end
end
