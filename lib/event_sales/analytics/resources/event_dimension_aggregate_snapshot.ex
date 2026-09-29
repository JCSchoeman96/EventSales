defmodule EventSales.Analytics.Resources.EventDimensionAggregateSnapshot do
  @moduledoc """
  Durable event-scoped dimensional gross ticket aggregates.

  One normalized projection row per recognised-sales grain: ticket type,
  source-scoped product, or source-scoped variation. Population and reads are
  owned by later M5-02 slices; this resource defines schema and write invariants.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Analytics

  alias EventSales.Analytics.Validations.ValidateDimensionAggregateGrain
  alias EventSales.Analytics.Validations.ValidateDimensionSourceEvent
  alias EventSales.Analytics.Validations.ValidateDimensionTicketTypeEvent

  @dimension_kinds [:ticket_type, :source_product, :source_variation]

  @ticket_type_unique_index "analytics_event_dim_agg_snapshots_unique_ticket_type_idx"
  @source_product_unique_index "analytics_event_dim_agg_snapshots_unique_source_product_idx"
  @source_variation_unique_index "analytics_event_dim_agg_snapshots_unique_source_variation_idx"
  @event_id_index "analytics_event_dim_agg_snapshots_event_id_idx"

  @grain_shape_check "analytics_event_dim_agg_snapshots_grain_shape_check"

  @grain_shape_check_sql """
  (
    (dimension_kind = 'ticket_type'
     AND ticket_type_id IS NOT NULL
     AND source_system_id IS NULL
     AND woo_product_id IS NULL
     AND woo_variation_id IS NULL)
    OR
    (dimension_kind = 'source_product'
     AND ticket_type_id IS NULL
     AND source_system_id IS NOT NULL
     AND woo_product_id IS NOT NULL
     AND woo_variation_id IS NULL)
    OR
    (dimension_kind = 'source_variation'
     AND ticket_type_id IS NULL
     AND source_system_id IS NOT NULL
     AND woo_product_id IS NOT NULL
     AND woo_variation_id IS NOT NULL)
  )
  """

  postgres do
    table "analytics_event_dimension_aggregate_snapshots"
    repo EventSales.Repo

    references do
      reference :event, on_delete: :delete, on_update: :update
      reference :ticket_type, on_delete: :restrict, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :event_id, name: @event_id_index

      index [:event_id, :currency, :ticket_type_id],
        unique: true,
        where: "dimension_kind = 'ticket_type'",
        name: @ticket_type_unique_index

      index [:event_id, :currency, :source_system_id, :woo_product_id],
        unique: true,
        where: "dimension_kind = 'source_product'",
        name: @source_product_unique_index

      index [:event_id, :currency, :source_system_id, :woo_product_id, :woo_variation_id],
        unique: true,
        where: "dimension_kind = 'source_variation'",
        name: @source_variation_unique_index
    end

    check_constraints do
      check_constraint :dimension_kind,
        name: @grain_shape_check,
        check: @grain_shape_check_sql

      check_constraint :gross_ticket_quantity,
        name: "analytics_event_dim_agg_snapshots_gross_ticket_quantity_check",
        check: "gross_ticket_quantity >= 0"

      check_constraint :gross_ticket_value,
        name: "analytics_event_dim_agg_snapshots_gross_ticket_value_check",
        check: "gross_ticket_value >= 0"

      check_constraint :woo_product_id,
        name: "analytics_event_dim_agg_snapshots_woo_product_id_check",
        check: "woo_product_id IS NULL OR woo_product_id > 0"

      check_constraint :woo_variation_id,
        name: "analytics_event_dim_agg_snapshots_woo_variation_id_check",
        check: "woo_variation_id IS NULL OR woo_variation_id > 0"
    end
  end

  actions do
    defaults [:read]

    create :create_snapshot do
      accept [
        :event_id,
        :currency,
        :dimension_kind,
        :ticket_type_id,
        :source_system_id,
        :woo_product_id,
        :woo_variation_id,
        :gross_ticket_quantity,
        :gross_ticket_value,
        :refreshed_at
      ]

      validate present([:event_id, :currency, :dimension_kind, :refreshed_at])
      validate {ValidateDimensionAggregateGrain, []}
      validate {ValidateDimensionTicketTypeEvent, []}
      validate {ValidateDimensionSourceEvent, []}
    end

    update :update_snapshot do
      accept [
        :gross_ticket_quantity,
        :gross_ticket_value,
        :refreshed_at
      ]

      require_atomic? false
    end

    destroy :destroy_snapshot do
      primary? true
      accept []
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :currency, :string do
      allow_nil? false
      public? true
    end

    attribute :dimension_kind, :atom do
      allow_nil? false
      constraints one_of: @dimension_kinds
      public? true
    end

    attribute :woo_product_id, :integer do
      public? true
    end

    attribute :woo_variation_id, :integer do
      public? true
    end

    attribute :gross_ticket_quantity, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :gross_ticket_value, :decimal do
      allow_nil? false
      default Decimal.new("0")
      constraints min: 0
      public? true
    end

    attribute :refreshed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    belongs_to :ticket_type, EventSales.Catalog.Resources.TicketType do
      public? true
    end

    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      public? true
    end
  end
end
