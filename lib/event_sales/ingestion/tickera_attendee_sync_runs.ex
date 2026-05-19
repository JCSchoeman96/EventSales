defmodule EventSales.Ingestion.TickeraAttendeeSyncRuns do
  @moduledoc """
  Facade for durable Tickera attendee sync run state.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraAttendeeSyncRun, TickeraEventSource}

  @default_limit 100
  @max_limit 500
  @authorized_context %{tickera_state_authorized?: true, tickera_state_authorized: true}

  def list_runs(opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraAttendeeSyncRun
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_run(id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      Ash.get(TickeraAttendeeSyncRun, id, domain: Ingestion)
    end
  end

  def queue_manual(%TickeraEventSource{} = source, attrs, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      attrs =
        attrs
        |> Map.put(:tickera_event_source_id, source.id)
        |> Map.put(:source_system_id, source.source_system_id)
        |> Map.put(:event_id, source.event_id)

      TickeraAttendeeSyncRun
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_create(:queue_manual, attrs)
      |> Ash.create(domain: Ingestion)
    end
  end

  def mark_started(%TickeraAttendeeSyncRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :start, opts)

  def mark_resumed(%TickeraAttendeeSyncRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :resume, opts)

  def mark_completed(%TickeraAttendeeSyncRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :complete, opts)

  def cancel(%TickeraAttendeeSyncRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :cancel, opts)

  def mark_paused(%TickeraAttendeeSyncRun{} = run, attrs, opts \\ []) do
    update_internal(run, attrs, :pause, opts)
  end

  def mark_failed(%TickeraAttendeeSyncRun{} = run, attrs, opts \\ []) do
    update_internal(run, attrs, :fail, opts)
  end

  def record_page(%TickeraAttendeeSyncRun{} = run, attrs, opts \\ []) do
    update_internal(run, attrs, :record_page, opts)
  end

  def record_counts(%TickeraAttendeeSyncRun{} = run, attrs, opts \\ []) do
    update_internal(run, attrs, :record_counts, opts)
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
