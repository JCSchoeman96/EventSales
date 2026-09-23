defmodule EventSales.Analytics.EventSnapshotRefreshFence do
  @moduledoc false

  alias EventSales.Repo

  @namespace "event_sales:analytics_event_snapshot_refresh:"

  @type error_reason ::
          :invalid_event_id
          | :event_snapshot_refresh_fence_transaction_required
          | :event_snapshot_refresh_fence_failed

  @spec acquire(Ecto.UUID.t() | String.t()) :: :ok | {:error, error_reason()}
  def acquire(event_id) when is_binary(event_id) do
    if Repo.in_transaction?() do
      case lock_key(event_id) do
        {:ok, key} -> pg_advisory_xact_lock(key)
        {:error, _} = error -> error
      end
    else
      {:error, :event_snapshot_refresh_fence_transaction_required}
    end
  rescue
    _error -> {:error, :event_snapshot_refresh_fence_failed}
  catch
    :exit, _reason -> {:error, :event_snapshot_refresh_fence_failed}
    :throw, _value -> {:error, :event_snapshot_refresh_fence_failed}
  end

  defp lock_key(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_event_id} ->
        <<key::signed-big-integer-size(64), _rest::binary>> =
          :crypto.hash(:sha256, @namespace <> canonical_event_id)

        {:ok, key}

      :error ->
        {:error, :invalid_event_id}
    end
  end

  defp pg_advisory_xact_lock(key) do
    case Repo.query("SELECT pg_advisory_xact_lock($1::bigint)", [key]) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :event_snapshot_refresh_fence_failed}
    end
  end
end
