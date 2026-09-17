defmodule EventSales.Ingestion.HistoricalCoverageFence do
  @moduledoc """
  Acquires transaction-scoped PostgreSQL advisory locks for historical coverage
  operations.

  Every caller must already be inside an `EventSales.Repo` transaction. The
  lock is held by PostgreSQL until that physical transaction commits or rolls
  back.
  """

  alias EventSales.Repo

  @namespace "event_sales:historical_coverage:"

  @type error_reason ::
          :invalid_event_id
          | :historical_coverage_fence_transaction_required
          | :historical_coverage_fence_failed

  @spec acquire(term()) :: :ok | {:error, error_reason()}
  def acquire(event_ids) do
    if Repo.in_transaction?() do
      with {:ok, keys} <- event_lock_keys(event_ids),
           :ok <- acquire_keys(keys) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :historical_coverage_fence_transaction_required}
    end
  rescue
    _error -> {:error, :historical_coverage_fence_failed}
  catch
    :exit, _reason -> {:error, :historical_coverage_fence_failed}
    :throw, _value -> {:error, :historical_coverage_fence_failed}
  end

  defp event_lock_keys(event_ids) when is_list(event_ids) do
    event_ids
    |> Enum.reduce_while({:ok, MapSet.new()}, fn event_id, {:ok, seen} ->
      case Ecto.UUID.cast(event_id) do
        {:ok, canonical_event_id} ->
          {:cont, {:ok, MapSet.put(seen, canonical_event_id)}}

        :error ->
          {:halt, {:error, :invalid_event_id}}
      end
    end)
    |> case do
      {:ok, event_ids} ->
        {:ok, Enum.map(Enum.sort(MapSet.to_list(event_ids)), &lock_key/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp event_lock_keys(_event_ids), do: {:error, :invalid_event_id}

  defp lock_key(canonical_event_id) do
    <<key::signed-big-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, @namespace <> canonical_event_id)

    key
  end

  defp acquire_keys([]), do: :ok

  defp acquire_keys([key | rest]) do
    case Repo.query("SELECT pg_advisory_xact_lock($1::bigint)", [key]) do
      {:ok, _result} -> acquire_keys(rest)
      {:error, _reason} -> {:error, :historical_coverage_fence_failed}
    end
  end
end
