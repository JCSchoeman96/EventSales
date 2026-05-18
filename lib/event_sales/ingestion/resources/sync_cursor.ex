defmodule EventSales.Ingestion.Resources.SyncCursor do
  @moduledoc """
  Per-run resumable cursor for WooCommerce order reconciliation.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.Validations.BoundedMetadata

  @statuses [:active, :done, :failed]
  @metadata_max_bytes 2048

  postgres do
    table "ingestion_sync_cursors"
    repo EventSales.Repo

    references do
      reference :sync_run, on_delete: :delete, on_update: :update
    end

    custom_indexes do
      index :sync_run_id,
        unique: true,
        name: "ingestion_sync_cursors_sync_run_id_idx"

      index :status, name: "ingestion_sync_cursors_status_idx"
      index :modified_after, name: "ingestion_sync_cursors_modified_after_idx"
    end
  end

  actions do
    defaults [:read]

    create :upsert_active do
      accept [
        :sync_run_id,
        :page,
        :modified_after,
        :modified_before,
        :last_seen_order_id,
        :metadata
      ]

      upsert? true
      upsert_identity :unique_sync_run

      upsert_fields [
        :page,
        :modified_after,
        :modified_before,
        :last_seen_order_id,
        :metadata,
        :status
      ]

      change set_attribute(:status, :active)
      validate present(:sync_run_id)
      validate {BoundedMetadata, max_bytes: @metadata_max_bytes}
    end

    update :mark_done do
      accept [:last_seen_order_id, :metadata]
      require_atomic? false
      change set_attribute(:status, :done)
      validate {BoundedMetadata, max_bytes: @metadata_max_bytes}
    end

    update :mark_failed do
      accept [:metadata]
      require_atomic? false
      change set_attribute(:status, :failed)
      validate {BoundedMetadata, max_bytes: @metadata_max_bytes}
    end
  end

  identities do
    identity :unique_sync_run, [:sync_run_id]
  end

  attributes do
    uuid_primary_key :id

    attribute :page, :integer do
      allow_nil? false
      default 1
      constraints min: 1
      public? true
    end

    attribute :modified_after, :utc_datetime_usec do
      public? true
    end

    attribute :modified_before, :utc_datetime_usec do
      public? true
    end

    attribute :last_seen_order_id, :integer do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      constraints one_of: @statuses
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :sync_run, EventSales.Ingestion.Resources.SyncRun do
      allow_nil? false
      public? true
    end
  end
end
