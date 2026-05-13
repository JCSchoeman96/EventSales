defmodule EventSales.AshBaseline.Resources.PaperTrailProof do
  @moduledoc """
  Proof-only resource used to verify AshPaperTrail integration in Slice 0.4.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.AshBaseline.Domain,
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ash_baseline_paper_trail_proofs"
    repo EventSales.Repo
  end

  actions do
    defaults [:read, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  paper_trail do
    change_tracking_mode :changes_only
    ignore_attributes [:inserted_at, :updated_at]
    ignore_actions [:create]
    on_actions [:update]
    store_action_name? true
    table_name "ash_baseline_paper_trail_proof_versions"
  end
end
