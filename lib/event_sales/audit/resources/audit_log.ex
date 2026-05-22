defmodule EventSales.Audit.Resources.AuditLog do
  @moduledoc """
  Durable operational audit event.

  This resource records security and operational events that are not resource
  mutation history. AshPaperTrail owns resource versions; AuditLog owns
  operator, worker, webhook, and system events.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Audit

  @event_types [
    :manual_sync_requested,
    :csv_apply_requested,
    :webhook_replay_requested,
    :webhook_replay_ignored,
    :webhook_duplicate_payload_mismatch,
    :webhook_stale_replay,
    :tickera_attendee_sync_requested,
    :tickera_reconciliation_run_requested,
    :event_sales_export_requested
  ]

  @actor_types [:system, :user, :worker, :webhook]
  @actor_roles [:admin, :staff, :event_owner, :event_staff]
  @sources [:admin, :worker, :webhook, :csv, :system]

  postgres do
    table "audit_logs"
    repo EventSales.Repo

    custom_indexes do
      index :event_type, name: "audit_logs_event_type_idx"
      index :actor_user_id, name: "audit_logs_actor_user_id_idx"
      index :event_id, name: "audit_logs_event_id_idx"
      index [:subject_type, :subject_id], name: "audit_logs_subject_idx"
      index :source, name: "audit_logs_source_idx"
      index :occurred_at, name: "audit_logs_occurred_at_idx"
    end
  end

  actions do
    defaults [:read]

    create :log do
      accept [
        :event_type,
        :actor_type,
        :actor_user_id,
        :actor_role,
        :subject_type,
        :subject_id,
        :event_id,
        :source,
        :metadata,
        :ip_hash,
        :user_agent_hash,
        :occurred_at
      ]

      validate present([:event_type, :actor_type, :source, :metadata, :occurred_at])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :atom do
      allow_nil? false
      constraints one_of: @event_types
      public? true
    end

    attribute :actor_type, :atom do
      allow_nil? false
      constraints one_of: @actor_types
      public? true
    end

    attribute :actor_user_id, :uuid do
      public? true
    end

    attribute :actor_role, :atom do
      constraints one_of: @actor_roles
      public? true
    end

    attribute :subject_type, :string do
      public? true
    end

    attribute :subject_id, :string do
      public? true
    end

    attribute :event_id, :uuid do
      public? true
    end

    attribute :source, :atom do
      allow_nil? false
      constraints one_of: @sources
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :ip_hash, :string do
      public? true
    end

    attribute :user_agent_hash, :string do
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
