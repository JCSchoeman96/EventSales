defmodule EventSales.Ingestion.Resources.TickeraReconciliationFinding do
  @moduledoc """
  Durable local Tickera/Woo reconciliation finding.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.Validations.AuthorizedTickeraStateMutation

  @finding_types [
    :woo_paid_missing_tickera,
    :tickera_paid_extra,
    :quantity_mismatch,
    :payment_status_mismatch,
    :ticket_type_mismatch,
    :stale_tickera_snapshot,
    :unmapped_woo_order_item,
    :no_tickera_source,
    :no_tickera_snapshots
  ]

  @severities [:critical, :warning, :info]
  @statuses [:open, :resolved, :ignored]

  @upsert_accept [
    :tickera_reconciliation_run_id,
    :tickera_event_source_id,
    :source_scope_key,
    :source_system_id,
    :event_id,
    :finding_type,
    :severity,
    :status,
    :order_id,
    :order_item_id,
    :tickera_attendee_snapshot_id,
    :ticket_type_id,
    :ticket_code,
    :checksum,
    :woo_order_status,
    :tickera_payment_status,
    :woo_quantity,
    :tickera_quantity,
    :details,
    :fingerprint,
    :first_seen_at,
    :last_seen_at
  ]

  @upsert_fields @upsert_accept --
                   [
                     :event_id,
                     :source_scope_key,
                     :fingerprint,
                     :first_seen_at
                   ]

  postgres do
    table "ingestion_tickera_reconciliation_findings"
    repo EventSales.Repo

    references do
      reference :tickera_reconciliation_run, on_delete: :restrict, on_update: :update
      reference :tickera_event_source, on_delete: :nilify, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
      reference :order, on_delete: :nilify, on_update: :update
      reference :order_item, on_delete: :nilify, on_update: :update
      reference :tickera_attendee_snapshot, on_delete: :nilify, on_update: :update
      reference :ticket_type, on_delete: :nilify, on_update: :update
    end

    custom_indexes do
      index :event_id, name: "ingestion_tickera_reconciliation_findings_event_id_idx"
      index :tickera_event_source_id, name: "ingestion_tickera_reconciliation_findings_source_idx"
      index :source_scope_key, name: "ingestion_tickera_reconciliation_findings_scope_idx"
      index :status, name: "ingestion_tickera_reconciliation_findings_status_idx"
      index :severity, name: "ingestion_tickera_reconciliation_findings_severity_idx"
      index :finding_type, name: "ingestion_tickera_reconciliation_findings_type_idx"
      index :inserted_at, name: "ingestion_tickera_reconciliation_findings_inserted_at_idx"

      index [:event_id, :status],
        name: "ingestion_tickera_reconciliation_findings_event_status_idx"

      index [:event_id, :severity],
        name: "ingestion_tickera_reconciliation_findings_event_severity_idx"

      index [:tickera_reconciliation_run_id, :finding_type],
        name: "ingestion_tickera_reconciliation_findings_run_type_idx"
    end

    identity_index_names unique_source_fingerprint:
                           "tickera_recon_findings_source_fingerprint_idx"
  end

  actions do
    defaults [:read]

    create :upsert_open do
      accept @upsert_accept
      upsert? true
      upsert_identity :unique_source_fingerprint
      upsert_fields @upsert_fields
      validate {AuthorizedTickeraStateMutation, []}

      validate present([
                 :tickera_reconciliation_run_id,
                 :source_scope_key,
                 :source_system_id,
                 :event_id,
                 :finding_type,
                 :severity,
                 :fingerprint,
                 :first_seen_at,
                 :last_seen_at
               ])

      change set_attribute(:status, :open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolution_reason, nil)
    end

    update :resolve do
      require_atomic? false
      accept [:resolution_reason]
      validate {AuthorizedTickeraStateMutation, []}
      change set_attribute(:status, :resolved)
      change &__MODULE__.set_resolved_at/2
    end

    update :ignore do
      require_atomic? false
      accept [:resolution_reason]
      validate {AuthorizedTickeraStateMutation, []}
      change set_attribute(:status, :ignored)
      change &__MODULE__.set_resolved_at/2
    end

    update :reopen do
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change set_attribute(:status, :open)
      change set_attribute(:resolved_at, nil)
      change set_attribute(:resolution_reason, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source_scope_key, :string do
      allow_nil? false
      public? true
    end

    attribute :finding_type, :atom do
      allow_nil? false
      constraints one_of: @finding_types
      public? true
    end

    attribute :severity, :atom do
      allow_nil? false
      constraints one_of: @severities
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :open
      constraints one_of: @statuses
      public? true
    end

    attribute :ticket_code, :string do
      public? true
    end

    attribute :checksum, :string do
      public? true
    end

    attribute :woo_order_status, :string do
      public? true
    end

    attribute :tickera_payment_status, :string do
      public? true
    end

    attribute :woo_quantity, :integer do
      constraints min: 0
      public? true
    end

    attribute :tickera_quantity, :integer do
      constraints min: 0
      public? true
    end

    attribute :details, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :fingerprint, :string do
      allow_nil? false
      public? true
    end

    attribute :first_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :resolved_at, :utc_datetime_usec do
      public? true
    end

    attribute :resolution_reason, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tickera_reconciliation_run,
               EventSales.Ingestion.Resources.TickeraReconciliationRun do
      allow_nil? false
      public? true
    end

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

    belongs_to :order, EventSales.Sales.Resources.Order do
      public? true
    end

    belongs_to :order_item, EventSales.Sales.Resources.OrderItem do
      public? true
    end

    belongs_to :tickera_attendee_snapshot,
               EventSales.Ingestion.Resources.TickeraAttendeeSnapshot do
      public? true
    end

    belongs_to :ticket_type, EventSales.Catalog.Resources.TicketType do
      public? true
    end
  end

  identities do
    identity :unique_source_fingerprint, [:event_id, :source_scope_key, :fingerprint]
  end

  def set_resolved_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :resolved_at, DateTime.utc_now())
  end
end
