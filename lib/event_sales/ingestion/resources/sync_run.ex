defmodule EventSales.Ingestion.Resources.SyncRun do
  @moduledoc """
  Tracks REST reconciliation/backfill runs for scoped WooCommerce order sync.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  alias EventSales.Ingestion.Validations.ScopedManualSync

  @requested_via_values [:manual, :scheduled, :system]
  @sync_modes [:shallow, :deep]
  @statuses [:queued, :running, :paused, :completed, :failed, :cancelled]
  @pause_reasons [:rate_limited, :timeout, :server_error, :circuit_open]

  @queue_manual_accept [
    :source_system_id,
    :event_id,
    :date_from,
    :date_to,
    :sync_mode,
    :requested_via
  ]

  postgres do
    table "ingestion_sync_runs"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :source_system_id, name: "ingestion_sync_runs_source_system_id_idx"
      index :event_id, name: "ingestion_sync_runs_event_id_idx"
      index :status, name: "ingestion_sync_runs_status_idx"
      index :started_at, name: "ingestion_sync_runs_started_at_idx"
      index :sync_mode, name: "ingestion_sync_runs_sync_mode_idx"
      index :requested_via, name: "ingestion_sync_runs_requested_via_idx"
    end
  end

  actions do
    defaults [:read]

    create :queue_manual_scoped do
      accept @queue_manual_accept
      change set_attribute(:status, :queued)
      change set_attribute(:requested_via, :manual)
      validate {ScopedManualSync, []}
    end

    update :start do
      require_atomic? false
      change transition_state(:running)
      change &__MODULE__.set_started_at/2
    end

    update :resume do
      require_atomic? false
      change transition_state(:running)
    end

    update :pause do
      require_atomic? false
      accept [:paused_until, :pause_reason, :last_error]
      validate present([:paused_until, :pause_reason])
      change transition_state(:paused)
    end

    update :complete do
      require_atomic? false
      change transition_state(:completed)
      change &__MODULE__.set_finished_at/2
    end

    update :fail do
      require_atomic? false
      accept [:last_error]
      change transition_state(:failed)
      change &__MODULE__.set_finished_at/2
    end

    update :cancel do
      require_atomic? false
      change transition_state(:cancelled)
      change &__MODULE__.set_finished_at/2
    end

    update :record_counts do
      accept [
        :orders_seen_count,
        :orders_matched_count,
        :orders_upserted_count,
        :orders_stale_count,
        :orders_failed_count,
        :errors_count
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :requested_via, :atom do
      allow_nil? false
      constraints one_of: @requested_via_values
      public? true
    end

    attribute :sync_mode, :atom do
      allow_nil? false
      constraints one_of: @sync_modes
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued
      constraints one_of: @statuses
      public? true
    end

    attribute :pause_reason, :atom do
      constraints one_of: @pause_reasons
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :finished_at, :utc_datetime_usec do
      public? true
    end

    attribute :paused_until, :utc_datetime_usec do
      public? true
    end

    attribute :date_from, :utc_datetime_usec do
      public? true
    end

    attribute :date_to, :utc_datetime_usec do
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :orders_seen_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :orders_matched_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :orders_upserted_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :orders_stale_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :orders_failed_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :errors_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
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

    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :start, from: :queued, to: :running
      transition :resume, from: :paused, to: :running
      transition :pause, from: :running, to: :paused
      transition :complete, from: :running, to: :completed
      transition :fail, from: :running, to: :failed
      transition :cancel, from: [:queued, :running], to: :cancelled
    end
  end

  def set_started_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :started_at, DateTime.utc_now())
  end

  def set_finished_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
  end
end
