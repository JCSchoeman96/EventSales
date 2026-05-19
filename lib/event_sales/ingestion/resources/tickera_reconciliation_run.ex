defmodule EventSales.Ingestion.Resources.TickeraReconciliationRun do
  @moduledoc """
  Durable state for one local Tickera/Woo reconciliation pass.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  alias EventSales.Ingestion.Validations.AuthorizedTickeraStateMutation

  @requested_via_values [:manual, :system]
  @statuses [:queued, :running, :completed, :failed, :cancelled]

  @create_accept [
    :tickera_event_source_id,
    :source_system_id,
    :event_id,
    :tickera_attendee_sync_run_id,
    :requested_via
  ]

  @count_fields [
    :woo_orders_scanned_count,
    :woo_items_scanned_count,
    :tickera_snapshots_scanned_count,
    :findings_created_count,
    :findings_open_count,
    :findings_resolved_count,
    :critical_count,
    :warning_count,
    :info_count
  ]

  postgres do
    table "ingestion_tickera_reconciliation_runs"
    repo EventSales.Repo

    references do
      reference :tickera_event_source, on_delete: :nilify, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
      reference :tickera_attendee_sync_run, on_delete: :nilify, on_update: :update
    end

    custom_indexes do
      index :tickera_event_source_id, name: "ingestion_tickera_reconciliation_runs_source_idx"
      index :source_system_id, name: "ingestion_tickera_reconciliation_runs_source_system_idx"
      index :event_id, name: "ingestion_tickera_reconciliation_runs_event_id_idx"
      index :status, name: "ingestion_tickera_reconciliation_runs_status_idx"
      index :inserted_at, name: "ingestion_tickera_reconciliation_runs_inserted_at_idx"

      index [:event_id, :status],
        name: "ingestion_tickera_reconciliation_runs_event_status_idx"

      index [:tickera_event_source_id, :status],
        name: "ingestion_tickera_reconciliation_runs_source_status_idx"
    end
  end

  actions do
    defaults [:read]

    create :queue_manual do
      accept @create_accept
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:source_system_id, :event_id])
      change set_attribute(:status, :queued)
      change set_attribute(:requested_via, :manual)
    end

    create :queue_system do
      accept @create_accept
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:source_system_id, :event_id])
      change set_attribute(:status, :queued)
      change set_attribute(:requested_via, :system)
    end

    update :start do
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change transition_state(:running)
      change &__MODULE__.set_started_at/2
    end

    update :complete do
      require_atomic? false
      accept @count_fields
      validate {AuthorizedTickeraStateMutation, []}
      change transition_state(:completed)
      change &__MODULE__.set_finished_at/2
    end

    update :fail do
      require_atomic? false
      accept [:last_error]
      validate {AuthorizedTickeraStateMutation, []}
      change transition_state(:failed)
      change &__MODULE__.set_finished_at/2
    end

    update :cancel do
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change transition_state(:cancelled)
      change &__MODULE__.set_finished_at/2
    end

    update :record_counts do
      require_atomic? false
      accept @count_fields
      validate {AuthorizedTickeraStateMutation, []}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :requested_via, :atom do
      allow_nil? false
      default :manual
      constraints one_of: @requested_via_values
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued
      constraints one_of: @statuses
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

    for field <- @count_fields do
      attribute field, :integer do
        allow_nil? false
        default 0
        constraints min: 0
        public? true
      end
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tickera_event_source, EventSales.Ingestion.Resources.TickeraEventSource do
      public? true
    end

    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end

    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    belongs_to :tickera_attendee_sync_run,
               EventSales.Ingestion.Resources.TickeraAttendeeSyncRun do
      public? true
    end

    has_many :findings, EventSales.Ingestion.Resources.TickeraReconciliationFinding do
      destination_attribute :tickera_reconciliation_run_id
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :start, from: :queued, to: :running
      transition :complete, from: :running, to: :completed
      transition :fail, from: :running, to: :failed
      transition :cancel, from: [:queued, :running], to: :cancelled
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
