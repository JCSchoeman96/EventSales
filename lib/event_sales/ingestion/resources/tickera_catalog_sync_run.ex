defmodule EventSales.Ingestion.Resources.TickeraCatalogSyncRun do
  @moduledoc """
  Durable dry-run/apply lifecycle for Tickera catalog sync.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  import Ash.Expr

  @statuses [
    :queued,
    :discovering,
    :retry_scheduled,
    :dry_run_ready,
    :applying,
    :applied,
    :failed,
    :cancelled
  ]
  @cancellation_reason_codes [
    :source_changed,
    :incorrect_scope,
    :unexpected_changes,
    :superseded,
    :operator_error,
    :other
  ]

  postgres do
    table "ingestion_tickera_catalog_sync_runs"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :requested_by_user, on_delete: :nilify, on_update: :update

      reference :cancelled_by_user,
        name: "catalog_sync_runs_cancelled_by_user_fkey",
        on_delete: :restrict,
        on_update: :update
    end

    custom_indexes do
      index :cancelled_by_user_id,
        name: "catalog_sync_runs_cancelled_by_user_idx"

      index :source_system_id,
        unique: true,
        where:
          "status IN ('queued', 'discovering', 'retry_scheduled', 'dry_run_ready', 'applying')",
        name: "ingestion_tickera_catalog_sync_runs_one_active_per_source_idx"
    end

    unique_index_names [
      {[:source_system_id], "ingestion_tickera_catalog_sync_runs_one_active_per_source_idx"}
    ]
  end

  actions do
    defaults [:read]

    create :create_dry_run do
      accept [
        :source_system_id,
        :requested_by_user_id,
        :scope
      ]

      validate present([:source_system_id, :scope])
    end

    update :mark_discovering do
      argument :owner_attempt, :integer, allow_nil?: false
      argument :owner_max_attempts, :integer, allow_nil?: false
      require_atomic? false
      change filter(expr(status in [:queued, :retry_scheduled, :discovering]))
      change set_attribute(:status, :discovering)
      change &__MODULE__.set_discovery_owner/2
      change &__MODULE__.set_started_at/2
    end

    update :mark_claim_failed do
      argument :owner_attempt, :integer, allow_nil?: false
      argument :owner_max_attempts, :integer, allow_nil?: false
      require_atomic? false
      change filter(expr(status in [:queued, :retry_scheduled, :discovering]))
      change set_attribute(:status, :failed)
      change set_attribute(:last_error, "catalog_sync_claim_failed")
      change &__MODULE__.set_discovery_owner/2
      change &__MODULE__.set_finished_at/2
    end

    update :mark_retry_scheduled do
      accept [:last_error, :retry_attempt, :retry_max_attempts]
      require_atomic? false
      change filter(expr(status == :discovering))
      change set_attribute(:status, :retry_scheduled)
    end

    update :mark_dry_run_ready do
      accept [:dry_run_hash, :summary, :plan_snapshot]
      require_atomic? false
      change filter(expr(status == :discovering))
      change set_attribute(:status, :dry_run_ready)
      change &__MODULE__.clear_retry_metadata/2
      change &__MODULE__.set_finished_at/2
    end

    update :claim_for_apply do
      require_atomic? false
      change filter(expr(status == :dry_run_ready))
      change set_attribute(:status, :applying)
    end

    update :mark_applied do
      require_atomic? false
      change filter(expr(status == :applying))
      change set_attribute(:status, :applied)
      change &__MODULE__.set_finished_at/2
    end

    update :mark_failed do
      accept [:last_error]
      require_atomic? false
      change filter(expr(status in [:discovering, :applying]))
      change set_attribute(:status, :failed)
      change &__MODULE__.set_finished_at/2
    end

    update :revoke_ready_dry_run do
      accept [
        :cancelled_by_user_id,
        :cancelled_at,
        :cancellation_reason_code,
        :cancellation_reason_details
      ]

      require_atomic? false
      change filter(expr(status == :dry_run_ready))
      change set_attribute(:status, :cancelled)
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
      constraints max_length: 120
      public? true
    end

    attribute :retry_attempt, :integer do
      constraints min: 1, max: 100
      public? true
    end

    attribute :retry_max_attempts, :integer do
      constraints min: 1, max: 100
      public? true
    end

    attribute :cancelled_at, :utc_datetime_usec do
      public? true
    end

    attribute :cancellation_reason_code, :atom do
      constraints one_of: @cancellation_reason_codes
      public? true
    end

    attribute :cancellation_reason_details, :string do
      constraints max_length: 500
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

    belongs_to :cancelled_by_user, EventSales.Accounts.Resources.User do
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

  def set_discovery_owner(changeset, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(
      :retry_attempt,
      Ash.Changeset.get_argument(changeset, :owner_attempt)
    )
    |> Ash.Changeset.force_change_attribute(
      :retry_max_attempts,
      Ash.Changeset.get_argument(changeset, :owner_max_attempts)
    )
  end

  def set_finished_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
  end

  def clear_retry_metadata(changeset, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:retry_attempt, nil)
    |> Ash.Changeset.force_change_attribute(:retry_max_attempts, nil)
    |> Ash.Changeset.force_change_attribute(:last_error, nil)
  end
end
