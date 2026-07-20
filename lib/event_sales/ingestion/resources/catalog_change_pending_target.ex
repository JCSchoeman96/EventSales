defmodule EventSales.Ingestion.Resources.CatalogChangePendingTarget do
  @moduledoc "Durable coalesced target and generation watermark for catalogue change dispatch."

  use Ash.Resource, data_layer: AshPostgres.DataLayer, domain: EventSales.Ingestion

  postgres do
    table "ingestion_catalog_change_pending_targets"
    repo EventSales.Repo
    identity_index_names unique_target: "ingestion_catalog_change_pending_targets_key_uidx"

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :catalog_sync_run, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [:source_system_id, :state, :quiet_until, :first_received_at, :id],
        name: "ingestion_catalog_change_pending_targets_due_idx"

      index [:source_system_id, :state, :recheck_at, :id],
        name: "ingestion_catalog_change_pending_targets_recheck_idx"

      index [:catalog_sync_run_id],
        where: "catalog_sync_run_id IS NOT NULL",
        name: "ingestion_catalog_change_pending_targets_run_idx"

      index [:updated_at, :id], name: "ingestion_catalog_change_pending_targets_admin_idx"
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :source_system_id,
        :target_type,
        :target_id,
        :latest_source_updated_at,
        :latest_reason,
        :first_received_at,
        :last_received_at,
        :quiet_until
      ]
    end

    update :transition do
      require_atomic? false

      accept [
        :state,
        :generation,
        :dispatched_generation,
        :latest_source_updated_at,
        :latest_reason,
        :last_received_at,
        :quiet_until,
        :recheck_at,
        :catalog_sync_run_id,
        :dispatch_attempts,
        :last_error
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :target_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:event, :product, :variation]],
      public?: true

    attribute :target_id, :integer, allow_nil?: false, constraints: [min: 1], public?: true

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :deferred, :queued, :preview_ready, :settled, :failed]],
      public?: true

    attribute :generation, :integer,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1],
      public?: true

    attribute :dispatched_generation, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0],
      public?: true

    attribute :latest_source_updated_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :latest_reason, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:saved, :metadata_changed, :status_changed, :trashed, :restored, :deleted]
      ],
      public?: true

    attribute :first_received_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_received_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :quiet_until, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :recheck_at, :utc_datetime_usec, public?: true

    attribute :dispatch_attempts, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0, max: 100],
      public?: true

    attribute :last_error, :string, constraints: [max_length: 120], public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem,
      allow_nil?: false,
      public?: true

    belongs_to :catalog_sync_run, EventSales.Ingestion.Resources.TickeraCatalogSyncRun,
      public?: true

    has_many :signals, EventSales.Ingestion.Resources.CatalogChangeSignal,
      destination_attribute: :pending_target_id,
      public?: true
  end

  identities do
    identity :unique_target, [:source_system_id, :target_type, :target_id]
  end
end
