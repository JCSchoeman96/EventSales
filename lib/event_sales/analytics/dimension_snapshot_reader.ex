defmodule EventSales.Analytics.DimensionSnapshotReader do
  @moduledoc """
  Cold derived read facade for event-scoped dimensional gross ticket aggregates.

  Reads durable `EventDimensionAggregateSnapshot` rows only. Authorization runs
  before any catalog or projection access. Canonical v2 and dimensional rows are
  read in one coherent transaction so refresh commits cannot split generations.

  Does not consult `AnalyticsReadinessResolver`; management surfaces gate
  analytics readiness before calling this module.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Analytics
  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Analytics.Resources.{EventAggregateSnapshot, EventDimensionAggregateSnapshot}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Repo

  @canonical_snapshot_version 2
  @dimension_kinds [:ticket_type, :source_product, :source_variation]

  @type currency_bucket :: %{
          currency: String.t(),
          dimensions: %{
            ticket_type: [ticket_type_row()],
            source_product: [source_product_row()],
            source_variation: [source_variation_row()]
          }
        }

  @type ticket_type_row :: %{
          ticket_type_id: Ecto.UUID.t(),
          gross_ticket_quantity: non_neg_integer(),
          gross_ticket_value: Decimal.t() | nil,
          ticket_type_name: String.t() | nil,
          capacity: non_neg_integer() | nil,
          active: boolean() | nil,
          ticket_type_display: :ok | :missing,
          refreshed_at: DateTime.t()
        }

  @type source_product_row :: %{
          source_system_id: Ecto.UUID.t(),
          woo_product_id: pos_integer(),
          gross_ticket_quantity: non_neg_integer(),
          gross_ticket_value: Decimal.t() | nil,
          source_system_name: String.t() | nil,
          source_system_display: :ok | :missing,
          refreshed_at: DateTime.t()
        }

  @type source_variation_row :: %{
          source_system_id: Ecto.UUID.t(),
          woo_product_id: pos_integer(),
          woo_variation_id: pos_integer(),
          gross_ticket_quantity: non_neg_integer(),
          gross_ticket_value: Decimal.t() | nil,
          source_system_name: String.t() | nil,
          source_system_display: :ok | :missing,
          refreshed_at: DateTime.t()
        }

  @type result :: %{
          event_id: Ecto.UUID.t(),
          revenue_visible?: boolean(),
          pii_visibility: :none,
          currencies: [currency_bucket()]
        }

  @doc """
  Returns dimensional snapshot breakdown for one event.

  Options:

    * `:actor` — required for authorized reads; `nil` yields `{:error, :forbidden}`
    * `:dimension_kind` — optional filter (`:ticket_type`, `:source_product`, `:source_variation`)
  """
  @spec list_for_event(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, result()}
          | :miss
          | :not_found
          | {:error,
             :forbidden
             | :snapshot_not_ready
             | :invalid_dimension_kind
             | {:invalid_uuid, :event_id}
             | term()}
  def list_for_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         :ok <- authorize(Keyword.get(opts, :actor), event_id),
         :ok <- validate_dimension_kind(Keyword.get(opts, :dimension_kind)),
         {:ok, coherent_payload} <- read_coherent_projection(event_id, opts) do
      {:ok, build_result(event_id, coherent_payload, Keyword.get(opts, :actor))}
    else
      {:coherent, :miss} -> :miss
      {:coherent, :not_found} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(actor, event_id) do
    if Policies.can_access_event_dashboard?(actor, event_id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_dimension_kind(nil), do: :ok

  defp validate_dimension_kind(kind) when kind in @dimension_kinds, do: :ok

  defp validate_dimension_kind(_kind), do: {:error, :invalid_dimension_kind}

  defp read_coherent_projection(event_id, opts) do
    dimension_kind = Keyword.get(opts, :dimension_kind)
    transaction_opts = EventSnapshotRefreshFence.coherent_transaction_opts()

    case Repo.transaction(
           fn -> coherent_projection_step(event_id, dimension_kind) end,
           transaction_opts
         ) do
      {:ok, :miss} -> {:coherent, :miss}
      {:ok, :not_found} -> {:coherent, :not_found}
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coherent_projection_step(event_id, dimension_kind) do
    with {:ok, true} <- event_exists?(event_id),
         {:ok, v2_rows} <- read_canonical_v2_snapshots(event_id),
         false <- v2_rows == [],
         {:ok, dim_rows_full} <- read_dimension_snapshots(event_id),
         :ok <- validate_projection_sets!(dim_rows_full, v2_rows),
         dim_rows_out <- filter_output_rows(dim_rows_full, dimension_kind) do
      %{v2_rows: v2_rows, dim_rows: dim_rows_out}
    else
      {:ok, false} -> :not_found
      true -> :miss
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp event_exists?(event_id) do
    Event
    |> Ash.Query.filter(id == ^event_id)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, %Event{}} -> {:ok, true}
      {:ok, nil} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_canonical_v2_snapshots(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and snapshot_version == ^@canonical_snapshot_version
    )
    |> Ash.Query.sort(currency: :asc)
    |> Ash.read(domain: Analytics)
  end

  defp read_dimension_snapshots(event_id) do
    EventDimensionAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(currency: :asc)
    |> Ash.read(domain: Analytics)
  end

  defp validate_projection_sets!(dim_rows_full, v2_rows) do
    v2_by_currency = Map.new(v2_rows, &{&1.currency, &1})
    v2_currency_set = MapSet.new(Map.keys(v2_by_currency))
    dimension_currency_set = MapSet.new(dim_rows_full, & &1.currency)

    if MapSet.subset?(dimension_currency_set, v2_currency_set) do
      validate_per_currency_readiness!(dim_rows_full, v2_by_currency)
    else
      {:error, :snapshot_not_ready}
    end
  end

  defp validate_per_currency_readiness!(dim_rows_full, v2_by_currency) do
    dim_by_currency = Enum.group_by(dim_rows_full, & &1.currency)

    v2_by_currency
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn currency, :ok ->
      v2 = Map.fetch!(v2_by_currency, currency)
      dims = Map.get(dim_by_currency, currency, [])

      case validate_currency_projection!(dims, v2) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_currency_projection!(dims, %EventAggregateSnapshot{} = v2) do
    with :ok <- validate_positive_gross_families!(dims, v2) do
      validate_generation_timestamps!(dims, v2)
    end
  end

  defp validate_positive_gross_families!(dims, v2) do
    if v2.gross_ticket_quantity > 0 do
      kinds = MapSet.new(dims, & &1.dimension_kind)

      if MapSet.member?(kinds, :ticket_type) and MapSet.member?(kinds, :source_product) do
        :ok
      else
        {:error, :snapshot_not_ready}
      end
    else
      :ok
    end
  end

  defp validate_generation_timestamps!(dims, v2) do
    v2_refreshed = truncate_refreshed_at(v2.refreshed_at)

    if Enum.all?(dims, &(truncate_refreshed_at(&1.refreshed_at) == v2_refreshed)) do
      :ok
    else
      {:error, :snapshot_not_ready}
    end
  end

  defp filter_output_rows(dim_rows_full, nil), do: dim_rows_full

  defp filter_output_rows(dim_rows_full, dimension_kind) do
    Enum.filter(dim_rows_full, &(&1.dimension_kind == dimension_kind))
  end

  defp build_result(event_id, %{v2_rows: v2_rows, dim_rows: dim_rows}, actor) do
    revenue_visible? = Policies.can_view_revenue?(actor, event_id)
    dim_by_currency = Enum.group_by(dim_rows, & &1.currency)

    currencies =
      v2_rows
      |> Enum.sort_by(& &1.currency)
      |> Enum.map(fn v2 ->
        rows = Map.get(dim_by_currency, v2.currency, [])
        %{currency: v2.currency, dimensions: build_dimensions_map(rows, revenue_visible?)}
      end)

    %{
      event_id: event_id,
      revenue_visible?: revenue_visible?,
      pii_visibility: :none,
      currencies: currencies
    }
  end

  defp build_dimensions_map(rows, revenue_visible?) do
    ticket_type_ids = Enum.map(rows, & &1.ticket_type_id)
    source_system_ids = Enum.map(rows, & &1.source_system_id)

    ticket_types = batch_ticket_types(ticket_type_ids)
    source_systems = batch_source_systems(source_system_ids)

    grouped =
      rows
      |> Enum.group_by(
        & &1.dimension_kind,
        &build_dimension_row(&1, revenue_visible?, ticket_types, source_systems)
      )

    %{
      ticket_type: sort_ticket_type_rows(Map.get(grouped, :ticket_type, [])),
      source_product: sort_source_product_rows(Map.get(grouped, :source_product, [])),
      source_variation: sort_source_variation_rows(Map.get(grouped, :source_variation, []))
    }
  end

  defp build_dimension_row(
         %EventDimensionAggregateSnapshot{} = row,
         revenue_visible?,
         ticket_types,
         source_systems
       ) do
    value =
      if revenue_visible? do
        row.gross_ticket_value
      else
        nil
      end

    case row.dimension_kind do
      :ticket_type ->
        enrich_ticket_type_row(row, value, ticket_types)

      :source_product ->
        enrich_source_product_row(row, value, source_systems)

      :source_variation ->
        enrich_source_variation_row(row, value, source_systems)
    end
  end

  defp enrich_ticket_type_row(row, gross_ticket_value, ticket_types) do
    ticket_type = Map.get(ticket_types, row.ticket_type_id)

    case ticket_type do
      %TicketType{} = tt ->
        %{
          ticket_type_id: row.ticket_type_id,
          gross_ticket_quantity: row.gross_ticket_quantity,
          gross_ticket_value: gross_ticket_value,
          ticket_type_name: tt.name,
          capacity: tt.capacity,
          active: tt.active,
          ticket_type_display: :ok,
          refreshed_at: row.refreshed_at
        }

      _ ->
        %{
          ticket_type_id: row.ticket_type_id,
          gross_ticket_quantity: row.gross_ticket_quantity,
          gross_ticket_value: gross_ticket_value,
          ticket_type_name: nil,
          capacity: nil,
          active: nil,
          ticket_type_display: :missing,
          refreshed_at: row.refreshed_at
        }
    end
  end

  defp enrich_source_product_row(row, gross_ticket_value, source_systems) do
    label_source_system(row, gross_ticket_value, source_systems, include_variation_id: false)
  end

  defp enrich_source_variation_row(row, gross_ticket_value, source_systems) do
    label_source_system(row, gross_ticket_value, source_systems, include_variation_id: true)
  end

  defp label_source_system(row, gross_ticket_value, systems, opts) do
    base = %{
      source_system_id: row.source_system_id,
      woo_product_id: row.woo_product_id,
      gross_ticket_quantity: row.gross_ticket_quantity,
      gross_ticket_value: gross_ticket_value,
      refreshed_at: row.refreshed_at
    }

    base =
      if Keyword.get(opts, :include_variation_id, false) do
        Map.put(base, :woo_variation_id, row.woo_variation_id)
      else
        base
      end

    case Map.get(systems, row.source_system_id) do
      %SourceSystem{name: name} ->
        Map.merge(base, %{source_system_name: name, source_system_display: :ok})

      _ ->
        Map.merge(base, %{source_system_name: nil, source_system_display: :missing})
    end
  end

  defp batch_ticket_types(ids) do
    ids = Enum.reject(ids, &is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      TicketType
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :name, :capacity, :active])
      |> Ash.read!(domain: Catalog)
      |> Map.new(&{&1.id, &1})
    end
  end

  defp batch_source_systems(ids) do
    ids = Enum.reject(ids, &is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      SourceSystem
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :name])
      |> Ash.read!(domain: Catalog)
      |> Map.new(&{&1.id, &1})
    end
  end

  defp sort_ticket_type_rows(rows) do
    Enum.sort_by(rows, & &1.ticket_type_id)
  end

  defp sort_source_product_rows(rows) do
    Enum.sort_by(rows, &{&1.source_system_id, &1.woo_product_id})
  end

  defp sort_source_variation_rows(rows) do
    Enum.sort_by(rows, &{&1.source_system_id, &1.woo_product_id, &1.woo_variation_id})
  end

  defp truncate_refreshed_at(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end
end
