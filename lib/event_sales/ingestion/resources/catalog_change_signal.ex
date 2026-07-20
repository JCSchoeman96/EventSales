defmodule EventSales.Ingestion.Resources.CatalogChangeSignal do
  @moduledoc "Immutable receipt for an authenticated catalogue change signal."

  use Ash.Resource, data_layer: AshPostgres.DataLayer, domain: EventSales.Ingestion

  postgres do
    table "ingestion_catalog_change_signals"
    repo EventSales.Repo

    identity_index_names unique_source_signal:
                           "ingestion_catalog_change_signals_source_signal_uidx"

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :pending_target, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [:pending_target_id, :inserted_at],
        name: "ingestion_catalog_change_signals_pending_inserted_idx"

      index [:inserted_at, :id], name: "ingestion_catalog_change_signals_inserted_idx"
    end
  end

  actions do
    defaults [:read]

    create :accept do
      accept [
        :source_system_id,
        :pending_target_id,
        :signal_id,
        :contract_version,
        :payload_hash,
        :target_type,
        :target_id,
        :source_updated_at,
        :reason,
        :disposition,
        :received_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :signal_id, :uuid, allow_nil?: false, public?: true
    attribute :contract_version, :string, allow_nil?: false, public?: true

    attribute :payload_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/^[a-f0-9]{64}$/],
      public?: true

    attribute :target_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:event, :product, :variation]],
      public?: true

    attribute :target_id, :integer, allow_nil?: false, constraints: [min: 1], public?: true
    attribute :source_updated_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :reason, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:saved, :metadata_changed, :status_changed, :trashed, :restored, :deleted]
      ],
      public?: true

    attribute :disposition, :atom,
      allow_nil?: false,
      constraints: [one_of: [:accepted, :stale]],
      public?: true

    attribute :received_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem,
      allow_nil?: false,
      public?: true

    belongs_to :pending_target, EventSales.Ingestion.Resources.CatalogChangePendingTarget,
      allow_nil?: false,
      public?: true
  end

  identities do
    identity :unique_source_signal, [:source_system_id, :signal_id]
  end
end
