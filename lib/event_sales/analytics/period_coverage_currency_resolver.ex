defmodule EventSales.Analytics.PeriodCoverageCurrencyResolver do
  @moduledoc false

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.EventAggregateSnapshot

  @canonical_snapshot_version 2

  @doc """
  Returns distinct canonical currency codes for one event from durable v2 event
  aggregate projections. One bounded set-based read.
  """
  @spec currencies_for_event(Ecto.UUID.t() | String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def currencies_for_event(event_id) when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_id} -> {:ok, query_currencies(canonical_id)}
      :error -> {:error, :invalid_event_id}
    end
  end

  defp query_currencies(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and snapshot_version == ^@canonical_snapshot_version
    )
    |> Ash.Query.select([:currency])
    |> Ash.read!(domain: Analytics)
    |> Enum.map(& &1.currency)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
