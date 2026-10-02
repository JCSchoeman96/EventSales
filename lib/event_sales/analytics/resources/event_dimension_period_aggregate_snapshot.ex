defmodule EventSales.Analytics.Resources.EventDimensionPeriodAggregateSnapshot do
  @moduledoc """
  Durable dimensional aggregate for one event, currency, and fixed bucket.

  Rows use the parallel ticket type, source product, and source variation
  grains. They contain additive gross and refund primitives only.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Analytics

  alias EventSales.Analytics.Validations.ValidateDimensionAggregateGrain
  alias EventSales.Analytics.Validations.ValidateDimensionSourceEvent
  alias EventSales.Analytics.Validations.ValidateDimensionTicketTypeEvent
  alias EventSales.Analytics.Validations.ValidatePeriodBucketContract

  @dimension_kinds [:ticket_type, :source_product, :source_variation]
  @projection_states [:current, :stale, :refresh_pending, :rebuilding, :unavailable]

  @bucket_timezone_check """
  (
    (bucket_kind = 'utc_hour' AND bucket_timezone = 'UTC')
    OR
    (bucket_kind = 'johannesburg_day' AND bucket_timezone = 'Africa/Johannesburg')
  )
  """

  @grain_shape_check """
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
    table "analytics_event_dimension_period_aggregate_snapshots"
    repo EventSales.Repo

    references do
      reference :event, on_delete: :delete, on_update: :update
      reference :ticket_type, on_delete: :restrict, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [
              :event_id,
              :currency,
              :bucket_kind,
              :bucket_start_utc,
              :bucket_end_utc,
              :ticket_type_id
            ],
            unique: true,
            where: "dimension_kind = 'ticket_type'",
            name: "analytics_dim_period_ticket_type_uidx"

      index [
              :event_id,
              :currency,
              :bucket_kind,
              :bucket_start_utc,
              :bucket_end_utc,
              :source_system_id,
              :woo_product_id
            ],
            unique: true,
            where: "dimension_kind = 'source_product'",
            name: "analytics_dim_period_source_product_uidx"

      index [
              :event_id,
              :currency,
              :bucket_kind,
              :bucket_start_utc,
              :bucket_end_utc,
              :source_system_id,
              :woo_product_id,
              :woo_variation_id
            ],
            unique: true,
            where: "dimension_kind = 'source_variation'",
            name: "analytics_dim_period_source_variation_uidx"
    end

    check_constraints do
      check_constraint :bucket_timezone,
        name: "analytics_dim_period_bucket_timezone_check",
        check: @bucket_timezone_check

      check_constraint :bucket_end_utc,
        name: "analytics_dim_period_bucket_bounds_check",
        check: "bucket_start_utc < bucket_end_utc"

      check_constraint :projection_state,
        name: "analytics_dim_period_projection_state_check",
        check:
          "projection_state IN ('current', 'stale', 'refresh_pending', 'rebuilding', 'unavailable')"

      check_constraint :semantic_version,
        name: "analytics_dim_period_semantic_version_check",
        check: "semantic_version >= 1"

      check_constraint :dimension_kind,
        name: "analytics_dim_period_grain_shape_check",
        check: @grain_shape_check

      check_constraint :gross_ticket_quantity,
        name: "analytics_dim_period_gross_quantity_check",
        check: "gross_ticket_quantity >= 0"

      check_constraint :gross_ticket_value,
        name: "analytics_dim_period_gross_value_check",
        check: "gross_ticket_value >= 0"

      check_constraint :refund_ticket_quantity,
        name: "analytics_dim_period_refund_quantity_check",
        check: "refund_ticket_quantity >= 0"

      check_constraint :refund_ticket_value,
        name: "analytics_dim_period_refund_value_check",
        check: "refund_ticket_value >= 0"

      check_constraint :woo_product_id,
        name: "analytics_dim_period_woo_product_id_check",
        check: "woo_product_id IS NULL OR woo_product_id > 0"

      check_constraint :woo_variation_id,
        name: "analytics_dim_period_woo_variation_id_check",
        check: "woo_variation_id IS NULL OR woo_variation_id > 0"
    end
  end

  actions do
    defaults [:read]

    create :create_snapshot do
      accept [
        :event_id,
        :currency,
        :bucket_kind,
        :bucket_start_utc,
        :bucket_end_utc,
        :bucket_timezone,
        :dimension_kind,
        :ticket_type_id,
        :source_system_id,
        :woo_product_id,
        :woo_variation_id,
        :gross_ticket_quantity,
        :gross_ticket_value,
        :refund_ticket_quantity,
        :refund_ticket_value,
        :generation_id,
        :semantic_version,
        :coverage_identity,
        :projection_state,
        :refreshed_at,
        :source_watermark_at
      ]

      validate present([
                 :event_id,
                 :currency,
                 :bucket_kind,
                 :bucket_start_utc,
                 :bucket_end_utc,
                 :bucket_timezone,
                 :dimension_kind,
                 :generation_id,
                 :semantic_version,
                 :coverage_identity,
                 :projection_state,
                 :refreshed_at
               ])

      validate {ValidatePeriodBucketContract, []}
      validate {ValidateDimensionAggregateGrain, []}
      validate {ValidateDimensionTicketTypeEvent, []}
      validate {ValidateDimensionSourceEvent, []}
    end

    update :update_snapshot do
      accept [
        :gross_ticket_quantity,
        :gross_ticket_value,
        :refund_ticket_quantity,
        :refund_ticket_value,
        :generation_id,
        :semantic_version,
        :coverage_identity,
        :projection_state,
        :refreshed_at,
        :source_watermark_at
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

    attribute :bucket_kind, :atom do
      allow_nil? false
      constraints one_of: [:utc_hour, :johannesburg_day]
      public? true
    end

    attribute :bucket_start_utc, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :bucket_end_utc, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :bucket_timezone, :string do
      allow_nil? false
      public? true
    end

    attribute :dimension_kind, :atom do
      allow_nil? false
      constraints one_of: @dimension_kinds
      public? true
    end

    attribute :woo_product_id, :integer do
      constraints min: 1
      public? true
    end

    attribute :woo_variation_id, :integer do
      constraints min: 1
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

    attribute :refund_ticket_quantity, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :refund_ticket_value, :decimal do
      allow_nil? false
      default Decimal.new("0")
      constraints min: 0
      public? true
    end

    attribute :generation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :semantic_version, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :coverage_identity, :string do
      allow_nil? false
      public? true
    end

    attribute :projection_state, :atom do
      allow_nil? false
      constraints one_of: @projection_states
      public? true
    end

    attribute :refreshed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :source_watermark_at, :utc_datetime_usec do
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
