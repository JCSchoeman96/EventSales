defmodule EventSales.Catalog.SourceEventResolver do
  @moduledoc """
  Resolves exactly one `SourceSystem` and one source-scoped Tickera `Event`.

  Path 1 M2-01 operator identity path. Local Postgres/Ash only:

  - no fuzzy name matching
  - no Event create/import
  - no WooCommerce / Tickera REST
  - no Redis / ETS / Cachex / GenServer identity authority

  Source identity follows M1-02:

  - `internal_source_pk` via `SourceSystem.id`
  - `canonical_source_key` via `kind` + `NormalizeBaseUrl.normalize/1`

  Event identity is source-scoped:

  `(source_system_id, external_event_kind = :tickera_event, external_event_id)`

  Uniqueness is enforced by the existing partial unique index
  `catalog_events_unique_external_tickera_event_idx`.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Changes.NormalizeBaseUrl
  alias EventSales.Catalog.Resources.{Event, SourceSystem}

  @type source_ref ::
          Ecto.UUID.t()
          | %{required(:kind) => atom(), required(:base_url) => String.t()}
          | keyword()

  @type resolution :: %{
          source_system: SourceSystem.t(),
          event: Event.t()
        }

  @type error ::
          :source_not_found
          | :source_lookup_failed
          | :event_not_found
          | :event_lookup_failed
          | :unsupported_external_event_kind
          | :invalid_source_ref
          | :invalid_external_event_id

  @doc """
  Resolves one SourceSystem and one Tickera Event from exact identity input.

  Options:

  - `:external_event_kind` — defaults to `:tickera_event`; any other value fails closed

  Absence vs lookup failure:

  - `:source_not_found` / `:event_not_found` — lookup succeeded; identity is absent
    (`{:ok, nil}` or Ash `Query.NotFound`)
  - `:source_lookup_failed` / `:event_lookup_failed` — identity truth could not be established
  """
  @spec resolve(source_ref(), integer(), keyword()) ::
          {:ok, resolution()} | {:error, error()}
  def resolve(source_ref, external_event_id, opts \\ [])

  def resolve(source_ref, external_event_id, opts)
      when is_integer(external_event_id) and external_event_id > 0 and is_list(opts) do
    external_event_kind = Keyword.get(opts, :external_event_kind, :tickera_event)

    with :ok <- validate_external_event_kind(external_event_kind),
         {:ok, %SourceSystem{} = source} <- fetch_source(source_ref),
         {:ok, %Event{} = event} <-
           fetch_tickera_event(source.id, external_event_id, external_event_kind) do
      {:ok, %{source_system: source, event: event}}
    end
  end

  def resolve(_source_ref, _external_event_id, _opts), do: {:error, :invalid_external_event_id}

  defp validate_external_event_kind(:tickera_event), do: :ok
  defp validate_external_event_kind(_), do: {:error, :unsupported_external_event_kind}

  defp fetch_source(source_system_id) when is_binary(source_system_id) do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      {:ok, nil} -> {:error, :source_not_found}
      {:error, reason} -> classify_source_lookup_error(reason)
    end
  end

  defp fetch_source(%{kind: kind, base_url: base_url})
       when is_atom(kind) and is_binary(base_url) do
    fetch_source_by_canonical_key(kind, base_url)
  end

  defp fetch_source(source_ref) when is_list(source_ref) do
    with {:ok, kind} <- fetch_keyword(source_ref, :kind),
         {:ok, base_url} <- fetch_keyword(source_ref, :base_url),
         true <- is_atom(kind),
         true <- is_binary(base_url) do
      fetch_source_by_canonical_key(kind, base_url)
    else
      _ -> {:error, :invalid_source_ref}
    end
  end

  defp fetch_source(_), do: {:error, :invalid_source_ref}

  defp fetch_source_by_canonical_key(kind, base_url) do
    normalized_base_url = NormalizeBaseUrl.normalize(base_url)

    case Ash.get(SourceSystem, %{kind: kind, base_url: normalized_base_url}, domain: Catalog) do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      {:ok, nil} -> {:error, :source_not_found}
      {:error, reason} -> classify_source_lookup_error(reason)
    end
  end

  defp fetch_keyword(list, key) do
    case Keyword.fetch(list, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_tickera_event(source_system_id, external_event_id, :tickera_event) do
    # DB partial unique index guarantees at most one row for this tuple when
    # external_event_kind and external_event_id are both set.
    Event
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        external_event_kind == :tickera_event and
        external_event_id == ^external_event_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, reason} -> classify_event_lookup_error(reason)
    end
  end

  # Ash.get expresses authoritative absence as Query.NotFound; Ash.read_one uses {:ok, nil}.
  defp classify_source_lookup_error(%Ash.Error.Invalid{
         errors: [%Ash.Error.Query.NotFound{} | _]
       }),
       do: {:error, :source_not_found}

  defp classify_source_lookup_error(_reason), do: {:error, :source_lookup_failed}

  defp classify_event_lookup_error(%Ash.Error.Invalid{
         errors: [%Ash.Error.Query.NotFound{} | _]
       }),
       do: {:error, :event_not_found}

  defp classify_event_lookup_error(_reason), do: {:error, :event_lookup_failed}
end
