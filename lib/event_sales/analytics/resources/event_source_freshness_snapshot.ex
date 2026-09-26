defmodule EventSales.Analytics.Resources.EventSourceFreshnessSnapshot do
  @moduledoc """
  Durable event-scoped source-freshness projection.

  One row per event stores monotonic component watermarks. The authoritative
  freshness anchor is derived on read; it is not persisted on this resource.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Analytics

  postgres do
    table "analytics_event_source_freshness_snapshots"
    repo EventSales.Repo

    identity_index_names unique_event: "analytics_event_source_freshness_snapshots_event_id_idx"

    references do
      reference :event, on_delete: :delete, on_update: :update
    end
  end

  actions do
    defaults [:read]

    create :advance_order_watermark do
      accept [:event_id, :order_source_watermark_at, :projection_refreshed_at]

      upsert? true
      upsert_identity :unique_event
      upsert_fields [:order_source_watermark_at, :projection_refreshed_at]

      upsert_condition expr(
                         is_nil(order_source_watermark_at) or
                           order_source_watermark_at < upsert_conflict(:order_source_watermark_at)
                       )

      validate present([:event_id, :order_source_watermark_at, :projection_refreshed_at])
    end

    create :advance_refund_watermark do
      accept [:event_id, :refund_source_watermark_at, :projection_refreshed_at]

      upsert? true
      upsert_identity :unique_event
      upsert_fields [:refund_source_watermark_at, :projection_refreshed_at]

      upsert_condition expr(
                         is_nil(refund_source_watermark_at) or
                           refund_source_watermark_at <
                             upsert_conflict(:refund_source_watermark_at)
                       )

      validate present([:event_id, :refund_source_watermark_at, :projection_refreshed_at])
    end

    create :advance_sync_source_observed do
      accept [:event_id, :sync_source_observed_at, :projection_refreshed_at]

      upsert? true
      upsert_identity :unique_event
      upsert_fields [:sync_source_observed_at, :projection_refreshed_at]

      upsert_condition expr(
                         is_nil(sync_source_observed_at) or
                           sync_source_observed_at < upsert_conflict(:sync_source_observed_at)
                       )

      validate present([:event_id, :sync_source_observed_at, :projection_refreshed_at])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :order_source_watermark_at, :utc_datetime_usec do
      public? true
    end

    attribute :refund_source_watermark_at, :utc_datetime_usec do
      public? true
    end

    attribute :sync_source_observed_at, :utc_datetime_usec do
      public? true
    end

    attribute :projection_version, :integer do
      allow_nil? false
      default 1
      constraints min: 1
      public? true
    end

    attribute :projection_refreshed_at, :utc_datetime_usec do
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
  end

  identities do
    identity :unique_event, [:event_id]
  end
end
