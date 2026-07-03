defmodule EventSales.Ingestion.Resources.TickeraCatalogSyncRun do
  @moduledoc """
  Durable dry-run/apply lifecycle for Tickera catalog sync.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  @statuses [:queued, :discovering, :dry_run_ready, :applying, :applied, :failed, :cancelled]

  postgres do
    table "ingestion_tickera_catalog_sync_runs"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :requested_by_user, on_delete: :nilify, on_update: :update
    end
  end

  actions do
    defaults [:read]

    create :create_dry_run do
      accept [
        :source_system_id,
        :requested_by_user_id,
        :scope,
        :status,
        :dry_run_hash,
        :summary,
        :plan_snapshot,
        :started_at,
        :finished_at,
        :last_error
      ]

      validate present([:source_system_id, :scope])
    end

    update :mark_discovering do
      require_atomic? false
      change set_attribute(:status, :discovering)
      change &__MODULE__.set_started_at/2
    end

    update :mark_dry_run_ready do
      accept [:dry_run_hash, :summary, :plan_snapshot]
      require_atomic? false
      change set_attribute(:status, :dry_run_ready)
      change &__MODULE__.set_finished_at/2
    end

    update :mark_applying do
      require_atomic? false
      change set_attribute(:status, :applying)
    end

    update :mark_applied do
      require_atomic? false
      change set_attribute(:status, :applied)
      change &__MODULE__.set_finished_at/2
    end

    update :mark_failed do
      accept [:last_error]
      require_atomic? false
      change set_attribute(:status, :failed)
      change &__MODULE__.set_finished_at/2
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scope, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued
      constraints one_of: @statuses
      public? true
    end

    attribute :dry_run_hash, :string do
      public? true
    end

    attribute :summary, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :plan_snapshot, :map do
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end

    belongs_to :requested_by_user, EventSales.Accounts.Resources.User do
      public? true
    end

    has_many :findings, EventSales.Ingestion.Resources.TickeraCatalogSyncFinding do
      destination_attribute :run_id
    end
  end

  def set_started_at(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :started_at) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :started_at, DateTime.utc_now())
      _started_at -> changeset
    end
  end

  def set_finished_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
  end
end
