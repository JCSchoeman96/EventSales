defmodule EventSales.Ingestion.Resources.HistoricalOrderMembership do
  @moduledoc """
  Durable, run-scoped proof of an exact WooCommerce Order identity in a
  historical manifest.

  A missing row represents ABSENT. Rows are created only after a manifest
  member has completed its page work, then move through MANIFEST_RESOLVED
  and CATCHUP_RESOLVED. The relation stores identity, source timestamps, and
  bounded manifest Event-match state, not order payloads or customer data.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  @resolution_states [:manifest_resolved, :catchup_resolved]
  @event_match_states [:target, :non_target]

  postgres do
    table "ingestion_historical_order_memberships"
    repo EventSales.Repo

    unique_index_names [
      {[:sync_run_id, :source_order_id],
       "ingestion_historical_order_memberships_unique_run_order_index",
       "a source Order may occur once in a historical run"}
    ]

    references do
      reference :sync_run, on_delete: :delete, on_update: :update
    end
  end

  actions do
    defaults [:read]

    create :resolve_manifest do
      accept [
        :sync_run_id,
        :source_order_id,
        :manifest_source_created_at,
        :manifest_source_modified_at,
        :last_source_modified_at,
        :event_match_state
      ]

      upsert? true
      upsert_identity :unique_run_order

      upsert_fields [
        :manifest_source_created_at,
        :manifest_source_modified_at,
        :last_source_modified_at,
        :event_match_state
      ]
    end

    update :resolve_catchup do
      accept [:last_source_modified_at]
      require_atomic? false
      change transition_state(:catchup_resolved)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source_order_id, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :manifest_source_created_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :manifest_source_modified_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_source_modified_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :event_match_state, :atom do
      allow_nil? false
      default :non_target
      constraints one_of: @event_match_states
      public? true
    end

    attribute :resolution_state, :atom do
      allow_nil? false
      default :manifest_resolved
      constraints one_of: @resolution_states
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

  identities do
    identity :unique_run_order, [:sync_run_id, :source_order_id]
  end

  state_machine do
    state_attribute :resolution_state
    initial_states [:manifest_resolved]
    default_initial_state :manifest_resolved

    transitions do
      transition :resolve_catchup,
        from: [:manifest_resolved, :catchup_resolved],
        to: :catchup_resolved
    end
  end
end
