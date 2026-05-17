defmodule EventSales.Analytics.SnapshotStore.NoopAdapter do
  @moduledoc """
  Disabled warm snapshot adapter.

  Used when hot-state Redis snapshots are not configured. This keeps the hot
  ETS cache and PubSub path active without emitting Redis failure telemetry.
  """

  @behaviour EventSales.Analytics.SnapshotStore.Adapter

  @impl true
  def put(_key, _summary, _opts \\ []), do: :ok

  @impl true
  def list_event_summaries(_opts \\ []), do: {:ok, []}
end
