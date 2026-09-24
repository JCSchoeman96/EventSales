defmodule EventSales.Analytics.EventSnapshotRefreshFence do
  @moduledoc false

  alias EventSales.Repo

  @namespace "event_sales:analytics_event_snapshot_refresh:"

  @type error_reason :: :invalid_event_id | :event_snapshot_refresh_fence_failed

  @doc false
  @spec with_serial_event_refresh(Ecto.UUID.t() | String.t(), (-> result)) :: result
        when result: var
  def with_serial_event_refresh(event_id, fun) when is_binary(event_id) and is_function(fun, 0) do
    with {:ok, key} <- lock_key(event_id) do
      Repo.checkout(fn ->
        with :ok <- take_session_lock(key) do
          try do
            fun.()
          after
            release_session_lock!(key)
          end
        end
      end)
    end
  rescue
    _error -> {:error, :event_snapshot_refresh_fence_failed}
  catch
    :exit, _reason -> {:error, :event_snapshot_refresh_fence_failed}
    :throw, _value -> {:error, :event_snapshot_refresh_fence_failed}
  end

  @doc false
  @spec coherent_transaction_opts() :: Keyword.t()
  def coherent_transaction_opts do
    if use_repeatable_read_isolation?() do
      [isolation_level: :repeatable_read]
    else
      []
    end
  end

  @doc false
  @spec use_repeatable_read_isolation?() :: boolean()
  def use_repeatable_read_isolation? do
    Process.get(:ecto_sandbox_unboxed) == true or
      Repo.config()[:pool] != Ecto.Adapters.SQL.Sandbox
  end

  @doc false
  @spec connection_backend_pid() :: integer()
  def connection_backend_pid do
    %Postgrex.Result{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  @doc false
  @spec lock_key(Ecto.UUID.t() | String.t()) :: {:ok, integer()} | {:error, :invalid_event_id}
  def lock_key(event_id) when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_event_id} ->
        <<key::signed-big-integer-size(64), _rest::binary>> =
          :crypto.hash(:sha256, @namespace <> canonical_event_id)

        {:ok, key}

      :error ->
        {:error, :invalid_event_id}
    end
  end

  defp take_session_lock(key) do
    case Repo.query("SELECT pg_advisory_lock($1::bigint)", [key]) do
      {:ok, _} -> :ok
      {:error, _reason} -> {:error, :event_snapshot_refresh_fence_failed}
    end
  end

  defp release_session_lock!(key) do
    case Repo.query("SELECT pg_advisory_unlock($1::bigint)", [key]) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      {:ok, %{rows: [[false]]}} ->
        Repo.query!("SELECT pg_advisory_unlock_all()")
        :ok

      {:error, reason} ->
        raise "event snapshot refresh fence unlock failed: #{inspect(reason)}"
    end
  end
end
