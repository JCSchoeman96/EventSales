defmodule EventSales.AshBaseline.Resources.StateMachineProof do
  @moduledoc """
  Proof-only resource used to verify AshStateMachine integration in Slice 0.4.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.AshBaseline.Domain,
    extensions: [AshStateMachine]

  postgres do
    table "ash_baseline_state_machine_proofs"
    repo EventSales.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name]
      primary? true
    end

    update :activate do
      change transition_state(:active)
    end

    update :archive do
      change transition_state(:archived)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :activate, from: :draft, to: :active
      transition :archive, from: :active, to: :archived
    end
  end
end
