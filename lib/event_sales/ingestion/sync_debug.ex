defmodule EventSales.Ingestion.SyncDebug do
  @moduledoc """
  Admin read facade for reconciliation sync run history.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun

  @default_per_page 25
  @max_per_page 50

  @type page :: %{
          page: pos_integer(),
          per_page: pos_integer(),
          has_next?: boolean(),
          has_previous?: boolean()
        }

  @type row :: %{
          id: Ecto.UUID.t(),
          source_system_id: Ecto.UUID.t(),
          event_id: Ecto.UUID.t(),
          requested_via: atom(),
          sync_mode: atom(),
          status: atom(),
          date_from: DateTime.t(),
          date_to: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          paused_until: DateTime.t() | nil,
          pause_reason: atom() | nil,
          last_error: String.t() | nil,
          orders_seen_count: non_neg_integer(),
          orders_matched_count: non_neg_integer(),
          orders_upserted_count: non_neg_integer(),
          orders_stale_count: non_neg_integer(),
          orders_failed_count: non_neg_integer(),
          errors_count: non_neg_integer(),
          inserted_at: DateTime.t()
        }

  @spec list_runs(keyword()) :: {:ok, %{rows: [row()], page: page()}} | {:error, term()}
  def list_runs(opts \\ []) do
    with :ok <- authorize(opts),
         %{page: page, per_page: per_page, offset: offset} <- pagination(opts),
         {:ok, runs} <- read_runs(opts, per_page + 1, offset) do
      {visible_runs, has_next?} = split_page(runs, per_page)

      {:ok,
       %{
         rows: Enum.map(visible_runs, &to_row/1),
         page: page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec event_scope(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, %{event_id: Ecto.UUID.t(), source_system_id: Ecto.UUID.t()}}
          | {:error, :forbidden | :not_found | term()}
  def event_scope(event_id, opts \\ [])

  def event_scope(event_id, opts) when is_binary(event_id) do
    with :ok <- authorize(opts),
         {:ok, event_uuid} <- cast_uuid(event_id),
         {:ok, %Event{} = event} <- fetch_event(event_uuid) do
      {:ok, %{event_id: event.id, source_system_id: event.source_system_id}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  def event_scope(_event_id, _opts), do: {:error, :not_found}

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp pagination(opts) do
    page =
      opts
      |> Keyword.get(:page, 1)
      |> normalize_positive_integer(1)

    per_page =
      opts
      |> Keyword.get(:per_page, @default_per_page)
      |> normalize_positive_integer(@default_per_page)
      |> min(@max_per_page)

    %{page: page, per_page: per_page, offset: (page - 1) * per_page}
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp read_runs(opts, limit, offset) do
    base_query = SyncRun

    case event_id_filter(Keyword.get(opts, :event_id)) do
      :skip ->
        query_runs(base_query, limit, offset)

      {:ok, event_uuid} ->
        base_query
        |> Ash.Query.filter(event_id == ^event_uuid)
        |> query_runs(limit, offset)

      :invalid ->
        {:ok, []}
    end
  end

  defp query_runs(query, limit, offset) do
    query
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(domain: Ingestion)
  end

  defp event_id_filter(event_id) when event_id in [nil, ""], do: :skip

  defp event_id_filter(event_id) do
    case cast_uuid(to_string(event_id)) do
      {:ok, uuid} -> {:ok, uuid}
      {:error, _} -> :invalid
    end
  end

  defp fetch_event(event_id) do
    Ash.get(Event, event_id, domain: Catalog)
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp to_row(%SyncRun{} = run) do
    %{
      id: run.id,
      source_system_id: run.source_system_id,
      event_id: run.event_id,
      requested_via: run.requested_via,
      sync_mode: run.sync_mode,
      status: run.status,
      date_from: run.date_from,
      date_to: run.date_to,
      started_at: run.started_at,
      finished_at: run.finished_at,
      paused_until: run.paused_until,
      pause_reason: run.pause_reason,
      last_error: run.last_error,
      orders_seen_count: run.orders_seen_count,
      orders_matched_count: run.orders_matched_count,
      orders_upserted_count: run.orders_upserted_count,
      orders_stale_count: run.orders_stale_count,
      orders_failed_count: run.orders_failed_count,
      errors_count: run.errors_count,
      inserted_at: run.inserted_at
    }
  end

  defp split_page(rows, per_page) do
    visible_rows = Enum.take(rows, per_page)
    {visible_rows, length(rows) > per_page}
  end

  defp page_info(page, per_page, has_next?) do
    %{
      page: page,
      per_page: per_page,
      has_next?: has_next?,
      has_previous?: page > 1
    }
  end
end
