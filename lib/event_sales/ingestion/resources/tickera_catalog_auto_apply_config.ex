defmodule EventSales.Ingestion.Resources.TickeraCatalogAutoApplyConfig do
  @moduledoc "Durable singleton configuration for conservative catalog auto-Apply."

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  postgres do
    table "ingestion_tickera_catalog_auto_apply_configs"
    repo EventSales.Repo
    identity_index_names singleton: "tickera_auto_apply_config_singleton_idx"
    migration_defaults supported_snapshot_versions: "[\"tickera_catalog_plan.v2\"]"

    check_constraints do
      check_constraint :singleton_key,
        name: "tickera_catalog_auto_apply_configs_singleton_key_check",
        check: "singleton_key = 'global'"

      check_constraint :revision,
        name: "tickera_catalog_auto_apply_configs_revision_check",
        check: "revision >= 1"
    end
  end

  actions do
    defaults [:read]

    create :bootstrap do
      accept []
    end

    update :update_configuration do
      accept [:global_mode, :enabled_policy_versions, :supported_snapshot_versions]
      require_atomic? false
      change &__MODULE__.increment_revision_if_changed/2
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :singleton_key, :string do
      allow_nil? false
      default "global"
      public? true
    end

    attribute :global_mode, :atom do
      allow_nil? false
      default :disabled
      constraints one_of: [:disabled, :observe, :enabled]
      public? true
    end

    attribute :enabled_policy_versions, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :supported_snapshot_versions, {:array, :string} do
      allow_nil? false
      default ["tickera_catalog_plan.v2"]
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      default 1
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :singleton, [:singleton_key]
  end

  def increment_revision_if_changed(changeset, _context) do
    changed? =
      Enum.any?([:global_mode, :enabled_policy_versions, :supported_snapshot_versions], fn key ->
        Ash.Changeset.changing_attribute?(changeset, key)
      end)

    if changed? do
      current = changeset.data.revision || 1
      Ash.Changeset.force_change_attribute(changeset, :revision, current + 1)
    else
      changeset
    end
  end
end
