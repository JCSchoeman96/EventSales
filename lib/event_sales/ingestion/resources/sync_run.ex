defmodule EventSales.Ingestion.Resources.SyncRun do
  @moduledoc """
  Tracks REST reconciliation and historical backfill runs for scoped
  WooCommerce order sync.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  alias EventSales.Ingestion.Validations.ScopedManualSync

  @requested_via_values [:manual, :scheduled, :system]
  @sync_type_values [:reconciliation, :historical_backfill]
  @sync_modes [:shallow, :deep]
  @statuses [:queued, :running, :paused, :completed, :failed, :cancelled]
  @pause_reasons [:rate_limited, :timeout, :server_error, :circuit_open]
  @order_coverage_statuses [:incomplete, :complete, :failed]
  @refund_coverage_statuses [:not_started, :incomplete, :complete, :failed]

  @coverage_invalidation_reasons [
    :source_identity_conflict,
    :historical_attribution_changed,
    :source_range_gap,
    :historical_order_changed,
    :historical_refund_changed,
    :historical_fact_corrected,
    :currency_conflict,
    :financial_reconciliation_failed
  ]

  @active_historical_index_name "ingestion_sync_runs_active_historical_event_idx"

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

    unique_index_names [
      {[:source_system_id, :event_id], @active_historical_index_name,
       "an active historical backfill already exists"}
    ]

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

      index [:source_system_id, :event_id],
        unique: true,
        where: "sync_type = 'historical_backfill' AND status IN ('queued', 'running', 'paused')",
        name: @active_historical_index_name
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

    create :queue_historical_backfill do
      accept [:event_id, :date_to]
      change set_attribute(:sync_type, :historical_backfill)
      change set_attribute(:sync_mode, :deep)
      change set_attribute(:requested_via, :manual)
      change set_attribute(:status, :queued)
    end

    update :start do
      require_atomic? false
      change transition_state(:running)
      change &__MODULE__.set_started_at/2
    end

    update :resume do
      require_atomic? false
      change transition_state(:running)
      change set_attribute(:paused_until, nil)
      change set_attribute(:pause_reason, nil)
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

    update :fail_paused do
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

    update :record_coverage_certification do
      public? false
      require_atomic? false

      accept [:coverage_start, :sales_covered_through, :refunds_covered_through]
      validate &__MODULE__.validate_coverage_certification/2
      change &__MODULE__.record_coverage_certification/2
    end

    update :invalidate_order_coverage do
      public? false
      require_atomic? false

      accept [:coverage_invalidation_reason]
      validate present(:coverage_invalidation_reason)
      change &__MODULE__.invalidate_order_coverage/2
    end

    update :invalidate_refund_coverage do
      public? false
      require_atomic? false

      accept [:coverage_invalidation_reason]
      validate present(:coverage_invalidation_reason)
      change &__MODULE__.invalidate_refund_coverage/2
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :requested_via, :atom do
      allow_nil? false
      constraints one_of: @requested_via_values
      public? true
    end

    attribute :sync_type, :atom do
      allow_nil? false
      default :reconciliation
      constraints one_of: @sync_type_values
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

    attribute :coverage_start, :utc_datetime_usec do
      public? true
    end

    attribute :sales_covered_through, :utc_datetime_usec do
      public? true
    end

    attribute :refunds_covered_through, :utc_datetime_usec do
      public? true
    end

    attribute :order_coverage_status, :atom do
      allow_nil? false
      default :incomplete
      constraints one_of: @order_coverage_statuses
      public? true
    end

    attribute :refund_coverage_status, :atom do
      allow_nil? false
      default :not_started
      constraints one_of: @refund_coverage_statuses
      public? true
    end

    attribute :coverage_certified_at, :utc_datetime_usec do
      public? true
    end

    attribute :coverage_invalidated_at, :utc_datetime_usec do
      public? true
    end

    attribute :coverage_invalidation_reason, :atom do
      constraints one_of: @coverage_invalidation_reasons
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
      transition :fail_paused, from: :paused, to: :failed
      transition :cancel, from: [:queued, :running], to: :cancelled
    end
  end

  def set_started_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :started_at, DateTime.utc_now())
  end

  def set_finished_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
  end

  def validate_coverage_certification(changeset, _context) do
    sync_type = Ash.Changeset.get_attribute(changeset, :sync_type)
    coverage_start = Ash.Changeset.get_attribute(changeset, :coverage_start)
    sales_covered_through = Ash.Changeset.get_attribute(changeset, :sales_covered_through)
    refunds_covered_through = Ash.Changeset.get_attribute(changeset, :refunds_covered_through)
    coverage_certified_at = Ash.Changeset.get_attribute(changeset, :coverage_certified_at)

    cond do
      sync_type != :historical_backfill ->
        {:error, field: :sync_type, message: "must be a historical backfill"}

      is_nil(coverage_start) ->
        {:error, field: :coverage_start, message: "must be present"}

      is_nil(sales_covered_through) ->
        {:error, field: :sales_covered_through, message: "must be present"}

      is_nil(refunds_covered_through) ->
        {:error, field: :refunds_covered_through, message: "must be present"}

      invalid_sales_coverage_range?(coverage_start, sales_covered_through) ->
        {:error, field: :sales_covered_through, message: "must be on or after coverage_start"}

      not is_nil(coverage_certified_at) ->
        {:error, field: :coverage_certified_at, message: "coverage has already been certified"}

      true ->
        :ok
    end
  end

  defp invalid_sales_coverage_range?(
         %DateTime{} = coverage_start,
         %DateTime{} = sales_covered_through
       ) do
    DateTime.compare(coverage_start, sales_covered_through) == :gt
  end

  defp invalid_sales_coverage_range?(_coverage_start, _sales_covered_through), do: false

  def record_coverage_certification(changeset, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:order_coverage_status, :complete)
    |> Ash.Changeset.force_change_attribute(:refund_coverage_status, :complete)
    |> Ash.Changeset.force_change_attribute(:coverage_certified_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:coverage_invalidated_at, nil)
    |> Ash.Changeset.force_change_attribute(:coverage_invalidation_reason, nil)
  end

  def invalidate_order_coverage(changeset, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:order_coverage_status, :incomplete)
    |> Ash.Changeset.force_change_attribute(:refund_coverage_status, :incomplete)
    |> Ash.Changeset.force_change_attribute(:coverage_invalidated_at, DateTime.utc_now())
  end

  def invalidate_refund_coverage(changeset, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:refund_coverage_status, :incomplete)
    |> Ash.Changeset.force_change_attribute(:coverage_invalidated_at, DateTime.utc_now())
  end
end
