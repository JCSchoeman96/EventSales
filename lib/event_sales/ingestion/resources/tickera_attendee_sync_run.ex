defmodule EventSales.Ingestion.Resources.TickeraAttendeeSyncRun do
  @moduledoc """
  Durable state for future Tickera attendee sync runs.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  alias EventSales.Ingestion.Validations.AuthorizedTickeraStateMutation

  @requested_via_values [:manual, :system]
  @sync_modes [:full]
  @statuses [:queued, :running, :paused, :completed, :failed, :cancelled]
  @pause_reasons [
    :rate_limited,
    :timeout,
    :server_error,
    :transport_error,
    :duplicate_page,
    :manual
  ]

  postgres do
    table "ingestion_tickera_attendee_sync_runs"
    repo EventSales.Repo

    references do
      reference :tickera_event_source, on_delete: :restrict, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :tickera_event_source_id, name: "ingestion_tickera_attendee_sync_runs_source_idx"
      index :event_id, name: "ingestion_tickera_attendee_sync_runs_event_id_idx"
      index :source_system_id, name: "ingestion_tickera_attendee_sync_runs_source_system_id_idx"
      index :status, name: "ingestion_tickera_attendee_sync_runs_status_idx"
      index :inserted_at, name: "ingestion_tickera_attendee_sync_runs_inserted_at_idx"
      index [:event_id, :status], name: "ingestion_tickera_attendee_sync_runs_event_status_idx"

      index [:tickera_event_source_id, :status],
        name: "ingestion_tickera_attendee_sync_runs_source_status_idx"
    end
  end

  actions do
    defaults [:read]

    create :queue_manual do
      accept [:tickera_event_source_id, :source_system_id, :event_id, :requested_via, :sync_mode]
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:tickera_event_source_id, :source_system_id, :event_id])
      change set_attribute(:status, :queued)
      change set_attribute(:requested_via, :manual)
      change set_attribute(:sync_mode, :full)
    end

    update :start do
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change transition_state(:running)
      change &__MODULE__.set_started_at/2
    end

    update :pause do
      require_atomic? false
      accept [:paused_until, :pause_reason, :last_error]
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:paused_until, :pause_reason])
      change transition_state(:paused)
    end

    update :resume do
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change transition_state(:running)
      change set_attribute(:paused_until, nil)
      change set_attribute(:pause_reason, nil)
    end

    update :complete do
      require_atomic? false
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

    update :record_page do
      require_atomic? false
      accept [:current_page, :last_successful_page, :last_page_count, :last_page_signature]
      validate {AuthorizedTickeraStateMutation, []}
    end

    update :record_counts do
      require_atomic? false

      accept [
        :attendees_seen_count,
        :attendees_upserted_count,
        :attendees_failed_count,
        :duplicate_page_count,
        :errors_count
      ]

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

    attribute :sync_mode, :atom do
      allow_nil? false
      default :full
      constraints one_of: @sync_modes
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

    attribute :paused_until, :utc_datetime_usec do
      public? true
    end

    attribute :pause_reason, :atom do
      constraints one_of: @pause_reasons
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :current_page, :integer do
      allow_nil? false
      default 1
      constraints min: 1
      public? true
    end

    attribute :last_successful_page, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :attendees_seen_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :attendees_upserted_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :attendees_failed_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :duplicate_page_count, :integer do
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

    attribute :last_page_count, :integer do
      constraints min: 0
      public? true
    end

    attribute :last_page_signature, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tickera_event_source, EventSales.Ingestion.Resources.TickeraEventSource do
      allow_nil? false
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

    has_many :attendee_snapshots, EventSales.Ingestion.Resources.TickeraAttendeeSnapshot do
      destination_attribute :tickera_attendee_sync_run_id
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :start, from: :queued, to: :running
      transition :pause, from: :running, to: :paused
      transition :resume, from: :paused, to: :running
      transition :complete, from: :running, to: :completed
      transition :fail, from: [:queued, :running, :paused], to: :failed
      transition :cancel, from: [:queued, :running, :paused], to: :cancelled
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
