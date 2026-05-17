defmodule EventSales.Analytics.SnapshotStore.Adapter do
  @moduledoc """
  Behaviour for warm dashboard snapshot storage.
  """

  @callback put(String.t(), map(), keyword()) :: :ok | {:error, term()}
end
