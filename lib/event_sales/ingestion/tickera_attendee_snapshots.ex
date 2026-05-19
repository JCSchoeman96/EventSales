defmodule EventSales.Ingestion.TickeraAttendeeSnapshots do
  @moduledoc """
  Facade for durable Tickera attendee snapshots.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraAttendeeSnapshot

  @default_limit 100
  @max_limit 500
  @authorized_context %{tickera_state_authorized?: true, tickera_state_authorized: true}
  @drop_fields [
    :transaction_id,
    "transaction_id",
    :api_key,
    "api_key",
    :tickera_api_key,
    "tickera_api_key"
  ]

  def list_for_event(event_id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraAttendeeSnapshot
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def list_for_source(source_id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraAttendeeSnapshot
      |> Ash.Query.filter(tickera_event_source_id == ^source_id)
      |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_by_ticket_code(source_id, ticket_code, opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraAttendeeSnapshot
      |> Ash.Query.filter(tickera_event_source_id == ^source_id and ticket_code == ^ticket_code)
      |> Ash.read_one(domain: Ingestion)
    end
  end

  def upsert_from_tickera(attrs, opts \\ []) do
    with :ok <- authorize_internal(opts) do
      attrs =
        attrs
        |> Map.drop(@drop_fields)
        |> put_checked_in_argument()

      TickeraAttendeeSnapshot
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_create(:upsert_from_tickera, attrs)
      |> Ash.create(domain: Ingestion)
    end
  end

  defp put_checked_in_argument(attrs) do
    cond do
      Map.has_key?(attrs, :checked_in?) ->
        attrs

      Map.has_key?(attrs, "checked_in?") ->
        Map.put(attrs, :checked_in?, Map.get(attrs, "checked_in?"))

      true ->
        attrs
    end
  end

  defp authorize_read(opts) do
    cond do
      Keyword.get(opts, :internal?) == true -> :ok
      opts |> Keyword.get(:actor) |> Policies.global_admin?() -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp authorize_internal(opts) do
    if Keyword.get(opts, :internal?) == true do
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
