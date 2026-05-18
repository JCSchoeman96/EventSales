defmodule EventSales.Analytics.SnapshotStore.Adapter do
  @moduledoc """
  Behaviour for warm dashboard snapshot storage.
  """

  @callback put(String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback list_event_summaries(keyword()) ::
              {:ok, [%{event_id: String.t(), summary: map()}]} | {:error, term()}
end
