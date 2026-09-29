defmodule EventSales.Analytics.Workers.RefreshSnapshotWorker do
  @moduledoc """
  Refreshes scoped durable analytics reporting snapshots.
  """

  use Oban.Worker,
    queue: :analytics_rebuilds,
    max_attempts: 3,
    replace: [
      suspended: [:meta],
      scheduled: [:meta],
      available: [:meta],
      retryable: [:meta]
    ],
    unique: [
      period: :infinity,
      fields: [:worker, :queue, :args],
      keys: [:scope, :event_id, :business_date],
      states: ~w(suspended scheduled available retryable)a
    ]

  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Repo
  alias EventSales.Telemetry
  alias Oban.Job

  @pending_states ~w(suspended scheduled available retryable)
  @event_scheduler_lock_namespace "eventsales:analytics:event-snapshot-refresh:v1:"

  @doc "Enqueues a refresh request for one event."
  @spec enqueue_event(Ecto.UUID.t() | String.t(), keyword()) :: :ok | {:error, term()}
  def enqueue_event(event_id, opts \\ []) do
    enqueue_events([event_id], opts)
  end

  @doc "Enqueues deterministic, event-scoped refresh requests."
  @spec enqueue_events([Ecto.UUID.t() | String.t()], keyword()) :: :ok | {:error, term()}
  def enqueue_events(event_ids, opts \\ [])

  def enqueue_events(event_ids, opts) when is_list(event_ids) do
    with {:ok, canonical_event_ids} <- normalize_event_ids(event_ids) do
      insert_event_jobs(canonical_event_ids, opts)
    end
  end

  def enqueue_events(_event_ids, _opts), do: {:error, :invalid_event_ids}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "event", "event_id" => event_id}})
      when is_binary(event_id) do
    case cast_uuid(event_id) do
      {:ok, event_id} -> refresh(:event, fn -> SnapshotRefresh.refresh_event(event_id) end)
      :error -> :discard
    end
  end

  def perform(%Oban.Job{
        args: %{"scope" => "daily", "event_id" => event_id, "business_date" => business_date}
      })
      when is_binary(event_id) and is_binary(business_date) do
    with {:ok, event_id} <- cast_uuid(event_id),
         {:ok, date} <- Date.from_iso8601(business_date) do
      refresh(:daily, fn -> SnapshotRefresh.refresh_daily(event_id, date) end)
    else
      :error -> :discard
      {:error, _reason} -> :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp refresh(scope, fun) do
    started_at = System.monotonic_time()
    emit_start(scope)

    case fun.() do
      {:ok, _snapshot} ->
        emit_stop(scope, System.monotonic_time() - started_at)
        :ok

      {:error, reason} ->
        emit_exception(scope, reason)
        {:error, reason}
    end
  end

  defp emit_start(scope) do
    Telemetry.emit(Telemetry.snapshot_refresh_start(), %{count: 1}, %{
      scope: scope,
      source: :postgres
    })
  end

  defp emit_stop(scope, duration) do
    Telemetry.emit(Telemetry.snapshot_refresh_stop(), %{duration: duration}, %{
      result: :ok,
      scope: scope,
      source: :postgres
    })
  end

  defp emit_exception(scope, reason) do
    Telemetry.emit(Telemetry.snapshot_refresh_exception(), %{count: 1}, %{
      reason: low_cardinality_reason(reason),
      scope: scope,
      source: :postgres
    })
  end

  defp low_cardinality_reason(reason) when is_atom(reason), do: reason
  defp low_cardinality_reason({reason, _detail}) when is_atom(reason), do: reason
  defp low_cardinality_reason(_reason), do: :error

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp normalize_event_ids(event_ids) do
    Enum.reduce_while(event_ids, {:ok, MapSet.new()}, fn event_id, {:ok, normalized} ->
      case Ecto.UUID.cast(event_id) do
        {:ok, canonical_event_id} ->
          {:cont, {:ok, MapSet.put(normalized, canonical_event_id)}}

        :error ->
          {:halt, {:error, :invalid_event_id}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> MapSet.to_list() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_event_job(insert_job, event_id, trailing_attempt \\ 0) do
    case insert_job.(new_event_job(event_id)) do
      {:ok, %Job{id: job_id, conflict?: true}} when not is_nil(job_id) ->
        confirm_pending_conflict(insert_job, event_id, job_id, trailing_attempt)

      {:ok, %Job{id: job_id}} when not is_nil(job_id) ->
        :ok

      {:ok, %Job{}} ->
        {:error, :snapshot_refresh_enqueue_unconfirmed_conflict}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_snapshot_refresh_insert_result, other}}
    end
  end

  defp confirm_pending_conflict(insert_job, event_id, job_id, trailing_attempt) do
    case current_job_state(job_id) do
      {:ok, state} when state in @pending_states ->
        :ok

      {:ok, _non_pending_state} when trailing_attempt == 0 ->
        insert_event_job(insert_job, event_id, 1)

      {:ok, _non_pending_state} ->
        {:error, :snapshot_refresh_enqueue_unconfirmed_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_job_state(job_id) do
    case Repo.query("SELECT state::text FROM oban_jobs WHERE id = $1 FOR UPDATE", [job_id]) do
      {:ok, %{rows: [[state]]}} -> {:ok, state}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_snapshot_refresh_job_state_result, other}}
    end
  end

  defp insert_event_jobs(event_ids, opts) do
    insert_job =
      Keyword.get(opts, :oban_insert, fn changeset ->
        Oban.insert(changeset, retry: false)
      end)

    if Repo.in_transaction?() do
      insert_event_jobs_in_transaction(event_ids, insert_job)
    else
      insert_event_jobs_in_own_transaction(event_ids, insert_job)
    end
  end

  defp insert_event_jobs_in_own_transaction(event_ids, insert_job) do
    Repo.transaction(fn ->
      insert_event_jobs_or_rollback(event_ids, insert_job)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_event_jobs_or_rollback(event_ids, insert_job) do
    case insert_event_jobs_in_transaction(event_ids, insert_job) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_event_jobs_in_transaction(event_ids, insert_job) do
    Enum.reduce_while(event_ids, :ok, fn event_id, :ok ->
      with :ok <- acquire_event_scheduler_lock(event_id),
           :ok <- insert_event_job(insert_job, event_id) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp acquire_event_scheduler_lock(event_id) do
    Repo.query("SELECT pg_advisory_xact_lock($1)", [event_scheduler_lock_key(event_id)])
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_scheduler_lock_key(event_id) do
    <<lock_key::signed-big-64, _rest::binary>> =
      :crypto.hash(:sha256, @event_scheduler_lock_namespace <> event_id)

    lock_key
  end

  defp new_event_job(event_id) do
    new(%{"scope" => "event", "event_id" => event_id},
      schedule_in: 1,
      meta: %{"refresh_request_id" => Ecto.UUID.generate()}
    )
  end
end
