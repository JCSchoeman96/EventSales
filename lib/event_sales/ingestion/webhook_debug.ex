defmodule EventSales.Ingestion.WebhookDebug do
  @moduledoc """
  Admin read facade for webhook delivery debugging.

  The list path returns operational metadata for stored webhook events. Raw
  payload access is a separate admin-only call so UI code must make payload
  reveal explicit.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent

  @default_per_page 25
  @max_per_page 50
  @statuses [:queued, :processing, :processed, :failed, :ignored, :buffered]

  @type page :: %{
          page: pos_integer(),
          per_page: pos_integer(),
          has_next?: boolean(),
          has_previous?: boolean()
        }

  @type row :: %{
          id: Ecto.UUID.t(),
          topic: String.t(),
          resource_type: String.t(),
          resource_id: String.t(),
          delivery_id: String.t(),
          status: atom(),
          received_at: DateTime.t(),
          processed_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          processing_started_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          ignore_reason: atom() | nil,
          accepted_via: atom(),
          raw_body_size: non_neg_integer(),
          source_updated_at: DateTime.t() | nil,
          processing_attempt_count: non_neg_integer()
        }

  @spec list_events(keyword()) :: {:ok, %{rows: [row()], page: page()}} | {:error, term()}
  def list_events(opts \\ []) do
    with :ok <- authorize(opts),
         %{page: page, per_page: per_page, offset: offset} <- pagination(opts),
         {:ok, events} <- read_events(opts, per_page + 1, offset) do
      {visible_events, has_next?} = split_page(events, per_page)

      {:ok,
       %{
         rows: Enum.map(visible_events, &to_row/1),
         page: page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec get_payload(Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :forbidden | :not_found | term()}
  def get_payload(webhook_event_id, opts) when is_binary(webhook_event_id) do
    with :ok <- authorize(opts),
         {:ok, %WebhookEvent{} = event} <- fetch_event(webhook_event_id) do
      {:ok, event.payload}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  def get_payload(_webhook_event_id, _opts), do: {:error, :not_found}

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

  defp read_events(opts, limit, offset) do
    WebhookEvent
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_string(:topic, Keyword.get(opts, :topic))
    |> maybe_filter_string(:delivery_id, Keyword.get(opts, :delivery_id))
    |> maybe_filter_string(:resource_id, Keyword.get(opts, :resource_id))
    |> Ash.Query.sort(received_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(domain: Ingestion)
  end

  defp maybe_filter_status(query, status) do
    case normalize_status(status) do
      {:ok, status} -> Ash.Query.filter(query, status == ^status)
      :skip -> query
    end
  end

  defp normalize_status(status) when is_atom(status) and status in @statuses, do: {:ok, status}

  defp normalize_status(status) when is_binary(status) do
    case String.trim(status) do
      "" ->
        :skip

      value ->
        try do
          atom = String.to_existing_atom(value)
          if atom in @statuses, do: {:ok, atom}, else: :skip
        rescue
          ArgumentError -> :skip
        end
    end
  end

  defp normalize_status(_status), do: :skip

  defp maybe_filter_string(query, _field, value) when value in [nil, ""], do: query

  defp maybe_filter_string(query, field, value)
       when field in [:topic, :delivery_id, :resource_id] do
    trimmed = String.trim(to_string(value))

    filter_string(query, field, trimmed)
  end

  defp filter_string(query, _field, ""), do: query
  defp filter_string(query, :topic, value), do: Ash.Query.filter(query, topic == ^value)

  defp filter_string(query, :delivery_id, value),
    do: Ash.Query.filter(query, delivery_id == ^value)

  defp filter_string(query, :resource_id, value),
    do: Ash.Query.filter(query, resource_id == ^value)

  defp fetch_event(webhook_event_id) do
    WebhookEvent
    |> Ash.Query.filter(id == ^webhook_event_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
  end

  defp to_row(%WebhookEvent{} = event) do
    %{
      id: event.id,
      topic: event.topic,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      delivery_id: event.delivery_id,
      status: event.status,
      received_at: event.received_at,
      processed_at: event.processed_at,
      failed_at: event.failed_at,
      processing_started_at: event.processing_started_at,
      error_message: event.error_message,
      ignore_reason: event.ignore_reason,
      accepted_via: event.accepted_via,
      raw_body_size: event.raw_body_size,
      source_updated_at: event.source_updated_at,
      processing_attempt_count: event.processing_attempt_count
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
