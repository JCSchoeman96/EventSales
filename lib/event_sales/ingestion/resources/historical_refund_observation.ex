defmodule EventSales.Ingestion.Resources.HistoricalRefundObservation do
  @moduledoc """
  Durable proof that one historical Order's current refund reference set was
  observed from the source.

  The absence of this row means the source refund set is unobserved. The row
  does not contain refund IDs or financial payloads; those live in the child
  reference rows and Sales refund resources.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  @resolution_states [:manifest_resolved, :catchup_resolved]

  postgres do
    table "ingestion_historical_refund_observations"
    repo EventSales.Repo

    unique_index_names [
      {[:historical_order_membership_id],
       "ingestion_historical_refund_observations_membership_index",
       "a historical Order membership has one refund observation"}
    ]

    references do
      reference :historical_order_membership,
        on_delete: :delete,
        on_update: :update
    end

    identity_index_names unique_membership: "hist_refund_observations_membership_idx"
  end

  actions do
    defaults [:read]

    create :resolve_manifest do
      accept [:historical_order_membership_id, :reference_count, :observed_at]

      upsert? true
      upsert_identity :unique_membership
      upsert_fields [:reference_count, :observed_at]
    end

    update :resolve_catchup do
      accept [:reference_count, :observed_at]
      require_atomic? false
      change transition_state(:catchup_resolved)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :reference_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
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
    belongs_to :historical_order_membership,
               EventSales.Ingestion.Resources.HistoricalOrderMembership do
      allow_nil? false
      public? true
    end

    has_many :historical_refund_references,
             EventSales.Ingestion.Resources.HistoricalRefundReference do
      destination_attribute :historical_refund_observation_id
      public? true
    end
  end

  identities do
    identity :unique_membership, [:historical_order_membership_id]
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
