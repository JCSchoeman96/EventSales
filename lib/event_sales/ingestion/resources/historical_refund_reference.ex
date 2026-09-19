defmodule EventSales.Ingestion.Resources.HistoricalRefundReference do
  @moduledoc """
  Normalized source refund identity observed for one historical Order.

  Reference state is discovery evidence, not financial state. Durable money
  and line facts remain owned by `Sales.Resources.Refund` and `RefundLine`.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  @source_states [:present, :absent_confirmed]

  postgres do
    table "ingestion_historical_refund_references"
    repo EventSales.Repo

    unique_index_names [
      {[:historical_refund_observation_id, :woo_refund_id],
       "ingestion_historical_refund_references_observation_refund_index",
       "a refund identity occurs once per observation"}
    ]

    references do
      reference :historical_refund_observation,
        on_delete: :delete,
        on_update: :update
    end

    identity_index_names unique_observation_refund: "hist_refund_refs_observation_refund_idx"
  end

  actions do
    defaults [:read]

    create :observe_present do
      accept [:historical_refund_observation_id, :woo_refund_id, :last_observed_at]

      upsert? true
      upsert_identity :unique_observation_refund
      upsert_fields [:last_observed_at]
    end

    update :confirm_absent do
      accept [:last_observed_at]
      require_atomic? false
      change transition_state(:absent_confirmed)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :woo_refund_id, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :source_state, :atom do
      allow_nil? false
      default :present
      constraints one_of: @source_states
      public? true
    end

    attribute :last_observed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :historical_refund_observation,
               EventSales.Ingestion.Resources.HistoricalRefundObservation do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_observation_refund,
             [:historical_refund_observation_id, :woo_refund_id]
  end

  state_machine do
    state_attribute :source_state
    initial_states [:present]
    default_initial_state :present

    transitions do
      transition :confirm_absent, from: :present, to: :absent_confirmed
    end
  end
end
