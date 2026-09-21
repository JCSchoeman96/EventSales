defmodule EventSales.Ingestion.Resources.FinancialReconciliationRun do
  @moduledoc """
  Durable state for one financial reconciliation attempt against one exact M3 certificate.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  require Ash.Query

  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.Validations.AuthorizedFinancialReconciliationStateMutation

  @requested_via_values [:manual, :system]
  @statuses [:queued, :running, :passed, :mismatched, :superseded, :failed, :cancelled]
  @active_statuses [:queued, :running]
  @active_index_name "ingestion_fin_recon_runs_active_idx"

  postgres do
    table "ingestion_financial_reconciliation_runs"
    repo EventSales.Repo

    references do
      reference :historical_sync_run, on_delete: :restrict, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :event_id, name: "ingestion_fin_recon_runs_event_id_idx"
      index :historical_sync_run_id, name: "ingestion_fin_recon_runs_sync_run_id_idx"
      index :status, name: "ingestion_fin_recon_runs_status_idx"
      index :finished_at, name: "ingestion_fin_recon_runs_finished_at_idx"

      index [:event_id, :historical_sync_run_id, :finished_at],
        name: "ingestion_fin_recon_runs_cert_lookup_idx"

      index [:event_id, :historical_sync_run_id],
        unique: true,
        where: "status IN ('queued', 'running')",
        name: @active_index_name
    end
  end

  actions do
    defaults [:read]

    create :queue_manual do
      accept [:historical_sync_run_id]
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      validate present(:historical_sync_run_id)
      validate &__MODULE__.validate_current_certificate/2
      change &__MODULE__.copy_scope_from_sync_run/2
      change set_attribute(:status, :queued)
      change set_attribute(:requested_via, :manual)
    end

    create :queue_system do
      accept [:historical_sync_run_id]
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      validate present(:historical_sync_run_id)
      validate &__MODULE__.validate_current_certificate/2
      change &__MODULE__.copy_scope_from_sync_run/2
      change set_attribute(:status, :queued)
      change set_attribute(:requested_via, :system)
    end

    update :start do
      require_atomic? false
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      change transition_state(:running)
      change &__MODULE__.set_started_at/2
    end

    update :pass do
      require_atomic? false
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      change transition_state(:passed)
      change &__MODULE__.set_finished_at/2
    end

    update :mismatch do
      require_atomic? false
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      change transition_state(:mismatched)
      change &__MODULE__.set_finished_at/2
    end

    update :supersede do
      require_atomic? false
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      change transition_state(:superseded)
      change &__MODULE__.set_finished_at/2
    end

    update :fail do
      require_atomic? false
      accept [:last_error]
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      change transition_state(:failed)
      change &__MODULE__.set_finished_at/2
      change &__MODULE__.bound_last_error/2
    end

    update :cancel do
      require_atomic? false
      validate {AuthorizedFinancialReconciliationStateMutation, []}
      change transition_state(:cancelled)
      change &__MODULE__.set_finished_at/2
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

    attribute :coverage_start, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :sales_covered_through, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :refunds_covered_through, :utc_datetime_usec do
      allow_nil? false
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
    belongs_to :historical_sync_run, SyncRun do
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

    has_many :metrics, EventSales.Ingestion.Resources.FinancialReconciliationMetric do
      destination_attribute :financial_reconciliation_run_id
    end

    has_many :findings, EventSales.Ingestion.Resources.FinancialReconciliationFinding do
      destination_attribute :financial_reconciliation_run_id
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :start, from: :queued, to: :running
      transition :pass, from: :running, to: :passed
      transition :mismatch, from: :running, to: :mismatched
      transition :supersede, from: :running, to: :superseded
      transition :fail, from: :running, to: :failed
      transition :cancel, from: @active_statuses, to: :cancelled
    end
  end

  def validate_current_certificate(changeset, _context) do
    sync_run_id = Ash.Changeset.get_attribute(changeset, :historical_sync_run_id)

    with {:ok, %SyncRun{} = sync_run} <-
           Ash.get(SyncRun, sync_run_id, domain: EventSales.Ingestion),
         {:ok, current} <- HistoricalCoverageResolver.resolve_current(sync_run.event_id),
         true <- current.id == sync_run.id do
      :ok
    else
      false ->
        {:error,
         field: :historical_sync_run_id,
         message: "historical sync run is not the current M3 certificate"}

      {:error, :historical_coverage_not_current} ->
        {:error, field: :historical_sync_run_id, message: "historical coverage is not current"}

      {:error, :invalid_event_id} ->
        {:error,
         field: :historical_sync_run_id, message: "invalid event id for certificate lookup"}

      {:error, _reason} ->
        {:error,
         field: :historical_sync_run_id, message: "unable to verify current M3 certificate"}

      _other ->
        {:error, field: :historical_sync_run_id, message: "historical sync run not found"}
    end
  end

  def copy_scope_from_sync_run(changeset, _context) do
    sync_run_id = Ash.Changeset.get_attribute(changeset, :historical_sync_run_id)

    case Ash.get(SyncRun, sync_run_id, domain: EventSales.Ingestion) do
      {:ok, %SyncRun{} = sync_run} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:source_system_id, sync_run.source_system_id)
        |> Ash.Changeset.force_change_attribute(:event_id, sync_run.event_id)
        |> Ash.Changeset.force_change_attribute(:coverage_start, sync_run.coverage_start)
        |> Ash.Changeset.force_change_attribute(
          :sales_covered_through,
          sync_run.sales_covered_through
        )
        |> Ash.Changeset.force_change_attribute(
          :refunds_covered_through,
          sync_run.refunds_covered_through
        )

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :historical_sync_run_id,
          message: inspect(reason)
        )
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

  def bound_last_error(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :last_error) do
      nil ->
        changeset

      message ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :last_error,
          message |> to_string() |> String.slice(0, 500)
        )
    end
  end
end
