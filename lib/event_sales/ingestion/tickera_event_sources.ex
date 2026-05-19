defmodule EventSales.Ingestion.TickeraEventSources do
  @moduledoc """
  Admin facade for Tickera attendee feed configuration.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraEventSource

  @default_limit 100
  @max_limit 500
  @authorized_context %{tickera_state_authorized?: true, tickera_state_authorized: true}
  @forbidden_fields [:api_key, :tickera_api_key, "api_key", "tickera_api_key"]
  @immutable_update_fields [
    :source_system_id,
    "source_system_id",
    :event_id,
    "event_id"
  ]

  def list_sources(opts \\ []) do
    with :ok <- authorize_admin(opts) do
      TickeraEventSource
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_source(id, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      Ash.get(TickeraEventSource, id, domain: Ingestion)
    end
  end

  def get_source_for_event(event_id, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      TickeraEventSource
      |> Ash.Query.filter(event_id == ^event_id and active == true)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read_one(domain: Ingestion)
    end
  end

  def create_source(attrs, opts \\ []) do
    with :ok <- authorize_admin(opts),
         :ok <- reject_forbidden_fields(attrs) do
      TickeraEventSource
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create(domain: Ingestion)
    end
  end

  def update_source(%TickeraEventSource{} = source, attrs, opts \\ []) do
    with :ok <- authorize_admin(opts),
         :ok <- reject_forbidden_fields(attrs),
         :ok <- reject_immutable_update_fields(attrs) do
      source
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.update(domain: Ingestion)
    end
  end

  def activate_source(%TickeraEventSource{} = source, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      source
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_update(:activate, %{})
      |> Ash.update(domain: Ingestion)
    end
  end

  def deactivate_source(%TickeraEventSource{} = source, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      source
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_update(:deactivate, %{})
      |> Ash.update(domain: Ingestion)
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp reject_forbidden_fields(attrs) do
    if Enum.any?(@forbidden_fields, &Map.has_key?(attrs, &1)) do
      {:error, invalid_attrs_error(:api_key, "must not be provided")}
    else
      :ok
    end
  end

  defp reject_immutable_update_fields(attrs) do
    case Enum.find(@immutable_update_fields, &Map.has_key?(attrs, &1)) do
      nil ->
        :ok

      field ->
        {:error, invalid_attrs_error(immutable_field(field), "is immutable after create")}
    end
  end

  defp immutable_field(:source_system_id), do: :source_system_id
  defp immutable_field("source_system_id"), do: :source_system_id
  defp immutable_field(:event_id), do: :event_id
  defp immutable_field("event_id"), do: :event_id

  defp invalid_attrs_error(field, message) do
    %Ash.Error.Invalid{
      errors: [
        %Ash.Error.Changes.InvalidAttribute{
          field: field,
          message: message
        }
      ]
    }
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
