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
  @rest_request_stop [:event_sales, :rest, :request, :stop]
  @rest_request_exception [:event_sales, :rest, :request, :exception]
  @hot_state_rebuild_start [:event_sales, :hot_state, :rebuild, :start]
  @hot_state_rebuild_stop [:event_sales, :hot_state, :rebuild, :stop]
  @hot_state_rebuild_exception [:event_sales, :hot_state, :rebuild, :exception]

  @doc """
  Returns every custom EventSales telemetry event name defined in Slice 0.8.
  """
  @spec event_names() :: [event_name()]
  def event_names do
    [
      webhook_accepted(),
      webhook_rejected(),
      rest_request_stop(),
      rest_request_exception(),
      hot_state_rebuild_start(),
      hot_state_rebuild_stop(),
      hot_state_rebuild_exception()
    ]
  end

  @doc "Webhook was durably accepted by the intake boundary."
  @spec webhook_accepted() :: event_name()
  def webhook_accepted, do: @webhook_accepted

  @doc "Webhook was rejected before durable intake."
  @spec webhook_rejected() :: event_name()
  def webhook_rejected, do: @webhook_rejected

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

  @doc """
  Emits a telemetry event through the standard `:telemetry` application.
  """
  @spec emit(event_name(), measurements(), metadata()) :: :ok
  def emit(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end
end
