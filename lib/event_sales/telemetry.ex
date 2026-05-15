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
  @rest_request_stop [:event_sales, :rest, :request, :stop]
  @rest_request_exception [:event_sales, :rest, :request, :exception]
  @hot_state_rebuild_start [:event_sales, :hot_state, :rebuild, :start]
  @hot_state_rebuild_stop [:event_sales, :hot_state, :rebuild, :stop]
  @hot_state_rebuild_exception [:event_sales, :hot_state, :rebuild, :exception]
  @cache_invalidate [:event_sales, :cache, :invalidate]

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
      rest_request_stop(),
      rest_request_exception(),
      hot_state_rebuild_start(),
      hot_state_rebuild_stop(),
      hot_state_rebuild_exception(),
      cache_invalidate()
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

  @doc "Cache invalidation signal for an event scope (Slice 3.0 telemetry-only facade)."
  @spec cache_invalidate() :: event_name()
  def cache_invalidate, do: @cache_invalidate

  @doc """
  Emits a telemetry event through the standard `:telemetry` application.
  """
  @spec emit(event_name(), measurements(), metadata()) :: :ok
  def emit(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end
end
