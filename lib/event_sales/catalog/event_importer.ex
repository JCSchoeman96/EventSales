defmodule EventSales.Catalog.EventImporter do
  @moduledoc """
  Idempotent local Tickera Event import/link for Path 1 M2-02.

  Builds on `SourceEventResolver`:

  - exact existing Event is reused without mutable synchronization
  - only authoritative `:event_not_found` may create
  - lookup failures never create
  - concurrent create races re-resolve exact identity; DB unique index is authority

  Identity:

  `(source_system_id, external_event_kind = :tickera_event, external_event_id)`

  Names and slugs are never external identity authority.
  """

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.SourceEventResolver

  @external_unique_constraint "catalog_events_unique_external_tickera_event_idx"
  @slug_unique_constraint "catalog_events_unique_slug_per_source_index"

  @type attrs :: %{
          required(:external_event_id) => pos_integer(),
          required(:name) => String.t(),
          required(:slug) => String.t()
        }

  @type result :: %{
          event: Event.t(),
          outcome: :created | :existing
        }

  @type error ::
          SourceEventResolver.error()
          | :invalid_input
          | :slug_conflict
          | :event_create_failed

  @doc """
  Imports or reuses one exact Tickera Event under an internal SourceSystem.

  Caller supplies `source_system_id` (internal UUID) plus `external_event_id`,
  `name`, and `slug`. The importer sets `external_event_kind` to `:tickera_event`
  and does not accept caller overrides for source/event identity after selection.
  """
  @spec import_tickera_event(Ecto.UUID.t(), map()) :: {:ok, result()} | {:error, error()}
  def import_tickera_event(source_system_id, attrs)
      when is_binary(source_system_id) and is_map(attrs) do
    with {:ok, external_event_id} <- fetch_external_event_id(attrs),
         {:ok, name} <- fetch_required_string(attrs, :name),
         {:ok, slug} <- fetch_required_string(attrs, :slug) do
      case SourceEventResolver.resolve(source_system_id, external_event_id) do
        {:ok, %{event: %Event{} = event}} ->
          {:ok, %{event: event, outcome: :existing}}

        {:error, :event_not_found} ->
          create_or_recover(source_system_id, external_event_id, name, slug)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def import_tickera_event(_source_system_id, _attrs), do: {:error, :invalid_input}

  defp create_or_recover(source_system_id, external_event_id, name, slug) do
    create_attrs = %{
      source_system_id: source_system_id,
      external_event_kind: :tickera_event,
      external_event_id: external_event_id,
      name: name,
      slug: slug
    }

    case Ash.create(Event, create_attrs, action: :create, domain: Catalog) do
      {:ok, %Event{} = event} ->
        {:ok, %{event: event, outcome: :created}}

      {:error, create_error} ->
        recover_after_create_failure(source_system_id, external_event_id, create_error)
    end
  end

  defp recover_after_create_failure(source_system_id, external_event_id, create_error) do
    case SourceEventResolver.resolve(source_system_id, external_event_id) do
      {:ok, %{event: %Event{} = event}} ->
        {:ok, %{event: event, outcome: :existing}}

      {:error, :event_not_found} ->
        classify_create_error(create_error)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_external_event_id(attrs) do
    case Map.get(attrs, :external_event_id) || Map.get(attrs, "external_event_id") do
      id when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, :invalid_external_event_id}
    end
  end

  defp fetch_required_string(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    if is_binary(value) and String.trim(value) != "" do
      {:ok, value}
    else
      {:error, :invalid_input}
    end
  end

  defp classify_create_error(error) do
    cond do
      constraint_error?(error, @slug_unique_constraint) ->
        {:error, :slug_conflict}

      constraint_error?(error, @external_unique_constraint) ->
        # Concurrent winner should have been recovered by exact re-resolution.
        # Preserve failure when identity is still authoritatively absent.
        {:error, :event_create_failed}

      true ->
        {:error, :event_create_failed}
    end
  end

  defp constraint_error?(%Ash.Error.Invalid{errors: errors}, constraint_name) do
    Enum.any?(errors, &constraint_match?(&1, constraint_name))
  end

  defp constraint_error?(%Ash.Error.Unknown{errors: errors}, constraint_name) do
    Enum.any?(errors, &constraint_match?(&1, constraint_name))
  end

  defp constraint_error?(error, constraint_name) do
    error
    |> Ash.Error.to_error_class()
    |> case do
      %Ash.Error.Invalid{errors: errors} ->
        Enum.any?(errors, &constraint_match?(&1, constraint_name))

      %Ash.Error.Unknown{errors: errors} ->
        Enum.any?(errors, &constraint_match?(&1, constraint_name))

      _ ->
        false
    end
  end

  defp constraint_match?(
         %Ash.Error.Changes.InvalidAttribute{private_vars: private_vars},
         constraint_name
       ) do
    private_vars[:constraint] == constraint_name
  end

  defp constraint_match?(%Ash.Error.Unknown.UnknownError{error: message}, constraint_name)
       when is_binary(message) do
    String.contains?(message, constraint_name)
  end

  defp constraint_match?(_error, _constraint_name), do: false
end
