defmodule EventSales.Ingestion.TickeraReconciliationRuns do
  @moduledoc """
  Facade for durable Tickera/Woo reconciliation run state.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraEventSource, TickeraReconciliationRun}
  alias EventSales.Ingestion.Workers.ReconcileTickeraAttendeesWorker

  @default_limit 100
  @max_limit 500
  @authorized_context %{tickera_state_authorized?: true, tickera_state_authorized: true}

  def list_runs(opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraReconciliationRun
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_run(id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      Ash.get(TickeraReconciliationRun, id, domain: Ingestion)
    end
  end

  def queue_manual_for_event(event_id, opts \\ []) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    with :ok <- authorize_admin(opts),
         {:ok, event} <- Ash.get(Event, event_id, domain: Catalog),
         {:ok, source} <- active_source_for_event(event.id),
         {:ok, run} <- create_manual_run(event, source),
         {:ok, job} <- enqueue_run(run, oban_insert) do
      {:ok, %{reconciliation_run: run, job: job}}
    end
  end

  def queue_manual(%TickeraEventSource{} = source, attrs, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      attrs =
        attrs
        |> Map.new()
        |> Map.put(:tickera_event_source_id, source.id)
        |> Map.put(:source_system_id, source.source_system_id)
        |> Map.put(:event_id, source.event_id)

      create_run(attrs, :queue_manual)
    end
  end

  def mark_started(%TickeraReconciliationRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :start, opts)

  def mark_completed(%TickeraReconciliationRun{} = run, attrs, opts \\ []),
    do: update_internal(run, attrs, :complete, opts)

  def mark_failed(%TickeraReconciliationRun{} = run, attrs, opts \\ []),
    do: update_internal(run, attrs, :fail, opts)

  def cancel(%TickeraReconciliationRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :cancel, opts)

  def record_counts(%TickeraReconciliationRun{} = run, attrs, opts \\ []),
    do: update_internal(run, attrs, :record_counts, opts)

  defp active_source_for_event(event_id) do
    case TickeraEventSource
         |> Ash.Query.filter(event_id == ^event_id and active == true)
         |> Ash.Query.sort(inserted_at: :desc, id: :desc)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_manual_run(event, nil) do
    create_run(
      %{
        source_system_id: event.source_system_id,
        event_id: event.id
      },
      :queue_manual
    )
  end

  defp create_manual_run(_event, %TickeraEventSource{} = source) do
    create_run(
      %{
        tickera_event_source_id: source.id,
        source_system_id: source.source_system_id,
        event_id: source.event_id
      },
      :queue_manual
    )
  end

  defp create_run(attrs, action) do
    TickeraReconciliationRun
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(@authorized_context)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create(domain: Ingestion)
  end

  defp enqueue_run(run, oban_insert) do
    case oban_insert.(ReconcileTickeraAttendeesWorker.new(%{"reconciliation_run_id" => run.id})) do
      {:ok, job} ->
        {:ok, job}

      {:error, _reason} ->
        _ = cancel(run, internal?: true)
        {:error, :enqueue_failed}
    end
  end

  defp update_internal(run, attrs, action, opts) do
    with :ok <- authorize_internal_or_admin(opts) do
      run
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_update(action, attrs)
      |> Ash.update(domain: Ingestion)
    end
  end

  defp authorize_read(opts), do: authorize_internal_or_admin(opts)

  defp authorize_internal_or_admin(opts) do
    cond do
      Keyword.get(opts, :internal?) == true -> :ok
      opts |> Keyword.get(:actor) |> Policies.global_admin?() -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> normalize_limit()
    |> min(@max_limit)
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit
end
