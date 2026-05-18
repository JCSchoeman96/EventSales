defmodule EventSales.Analytics.Resources.DailySalesAggregateSnapshot do
  @moduledoc """
  Durable event/day historical reporting snapshot.

  This is a derived Postgres read model for trend reports. Sales order and
  order item rows remain durable source truth.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Analytics

  postgres do
    table "analytics_daily_sales_aggregate_snapshots"
    repo EventSales.Repo
    identity_index_names unique_event_day_timezone: "analytics_daily_snapshots_unique_scope_idx"

    references do
      reference :event, on_delete: :delete, on_update: :update
    end

    custom_indexes do
      index :event_id, name: "analytics_daily_sales_aggregate_snapshots_event_id_idx"
      index :business_date, name: "analytics_daily_sales_aggregate_snapshots_business_date_idx"
      index :refreshed_at, name: "analytics_daily_sales_aggregate_snapshots_refreshed_at_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_snapshot do
      accept [
        :event_id,
        :business_date,
        :total_sold,
        :total_revenue,
        :today_sold,
        :today_revenue,
        :status_breakdown,
        :currency,
        :business_timezone,
        :refreshed_at,
        :source_watermark_at,
        :source_row_count,
        :snapshot_version
      ]

      validate present([
                 :event_id,
                 :business_date,
                 :total_sold,
                 :total_revenue,
                 :today_sold,
                 :today_revenue,
                 :currency,
                 :business_timezone,
                 :refreshed_at,
                 :source_row_count,
                 :snapshot_version
               ])
    end

    update :update_snapshot do
      accept [
        :total_sold,
        :total_revenue,
        :today_sold,
        :today_revenue,
        :status_breakdown,
        :currency,
        :business_timezone,
        :refreshed_at,
        :source_watermark_at,
        :source_row_count,
        :snapshot_version
      ]

      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :business_date, :date do
      allow_nil? false
      public? true
    end

    attribute :total_sold, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :total_revenue, :decimal do
      allow_nil? false
      default Decimal.new("0")
      public? true
    end

    attribute :today_sold, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :today_revenue, :decimal do
      allow_nil? false
      default Decimal.new("0")
      public? true
    end

    attribute :status_breakdown, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :currency, :string do
      allow_nil? false
      public? true
    end

    attribute :business_timezone, :string do
      allow_nil? false
      public? true
    end

    attribute :refreshed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :source_watermark_at, :utc_datetime_usec do
      public? true
    end

    attribute :source_row_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :snapshot_version, :integer do
      allow_nil? false
      default 1
      constraints min: 1
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
  end

  identities do
    identity :unique_event_day_timezone, [:event_id, :business_date, :business_timezone]
  end
end
