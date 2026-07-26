defmodule EventSales.Ingestion.Resources.TickeraCatalogAutoApplyDecision do
  @moduledoc "Durable policy, enqueue and automatic Apply audit state."

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  import Ecto.Query

  postgres do
    table "ingestion_tickera_catalog_auto_apply_decisions"
    repo EventSales.Repo
    identity_index_names decision_identity: "tickera_auto_apply_decision_identity_idx"

    migration_defaults finding_summary: "nil",
                       action_summary: "nil",
                       historical_summary:
                         "%{\"affected_pending_lines\" => 0, \"affected_quantity\" => 0, \"eligible_lines\" => 0, \"deferred_lines\" => 0, \"conflicting_lines\" => 0, \"already_mapped_lines\" => 0, \"warning_count\" => 0, \"unresolved_destination_count\" => 0, \"unknown_classification_count\" => 0}"

    references do
      reference :catalog_sync_run, on_delete: :restrict, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :enqueue_key,
        unique: true,
        name: "tickera_catalog_auto_apply_decisions_enqueue_key_uidx"

      index :apply_job_id,
        unique: true,
        where: "apply_job_id IS NOT NULL",
        name: "tickera_catalog_auto_apply_decisions_apply_job_uidx"

      index [:source_system_id, :inserted_at, :id],
        name: "tickera_catalog_auto_apply_decisions_source_recent_idx"

      index [:next_attempt_at, :source_system_id, :id],
        where:
          "enqueue_state IN ('claimed', 'enqueued', 'retryable_failure') AND next_attempt_at IS NOT NULL",
        name: "tickera_catalog_auto_apply_decisions_recovery_idx"

      index [:policy_version, :snapshot_schema_version, :evaluated_at],
        name: "tickera_catalog_auto_apply_decisions_policy_audit_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_for_run do
      accept [
        :catalog_sync_run_id,
        :dry_run_hash,
        :snapshot_schema_version,
        :policy_version,
        :decision_result,
        :reason_codes,
        :finding_summary,
        :action_summary,
        :historical_summary,
        :origin,
        :evaluated_global_mode,
        :evaluated_source_mode,
        :effective_mode,
        :configuration_revision,
        :configuration_fingerprint,
        :enqueue_state,
        :apply_audit_state,
        :enqueue_key
      ]

      change &__MODULE__.copy_locked_run_source/2
      change &__MODULE__.set_evaluated_at/2
      change &__MODULE__.validate_closed_summaries/2
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :dry_run_hash, :string do
      allow_nil? false
      constraints match: ~r/^[0-9a-f]{64}$/
      public? true
    end

    attribute :snapshot_schema_version, :string do
      allow_nil? false
      constraints max_length: 80
      public? true
    end

    attribute :policy_version, :string do
      allow_nil? false
      constraints max_length: 80
      public? true
    end

    attribute :decision_result, :atom do
      allow_nil? false
      constraints one_of: [:observe, :eligible, :ineligible]
      public? true
    end

    attribute :enqueue_state, :atom do
      allow_nil? false
      default :not_applicable

      constraints one_of: [
                    :not_applicable,
                    :pending,
                    :claimed,
                    :enqueued,
                    :retryable_failure,
                    :terminal_failure,
                    :superseded
                  ]

      public? true
    end

    attribute :apply_audit_state, :atom do
      allow_nil? false
      default :not_started
      constraints one_of: [:not_started, :claim_rejected, :claimed, :completed, :failed]
      public? true
    end

    attribute :reason_codes, {:array, :string} do
      allow_nil? false
      default []
      constraints max_length: 32, items: [max_length: 80]
      public? true
    end

    attribute :finding_summary, :map do
      allow_nil? false
      default %{"total" => 0, "info" => 0, "warning" => 0, "blocking" => 0, "unknown" => 0}
      public? true
    end

    attribute :action_summary, :map do
      allow_nil? false

      default %{
        "event_create" => 0,
        "event_reuse" => 0,
        "ticket_type_create" => 0,
        "ticket_type_reuse" => 0,
        "product_mapping_create" => 0,
        "total" => 0
      }

      public? true
    end

    attribute :historical_summary, :map do
      allow_nil? false

      default %{
        "affected_pending_lines" => 0,
        "affected_quantity" => 0,
        "eligible_lines" => 0,
        "deferred_lines" => 0,
        "conflicting_lines" => 0,
        "already_mapped_lines" => 0,
        "warning_count" => 0,
        "unresolved_destination_count" => 0,
        "unknown_classification_count" => 0
      }

      public? true
    end

    attribute :origin, :atom do
      allow_nil? false
      constraints one_of: [:human_admin, :targeted_catalog_change, :legacy_unknown]
      public? true
    end

    attribute :evaluated_global_mode, :atom do
      allow_nil? false
      constraints one_of: [:disabled, :observe, :enabled]
      public? true
    end

    attribute :evaluated_source_mode, :atom do
      allow_nil? false
      constraints one_of: [:inherit, :disabled, :observe, :enabled]
      public? true
    end

    attribute :effective_mode, :atom do
      allow_nil? false
      constraints one_of: [:disabled, :observe, :enabled]
      public? true
    end

    attribute :configuration_revision, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :configuration_fingerprint, :string do
      allow_nil? false
      constraints match: ~r/^[0-9a-f]{64}$/
      public? true
    end

    attribute :enqueue_key, :string do
      constraints max_length: 160
      public? true
    end

    attribute :enqueue_attempts, :integer do
      allow_nil? false
      default 0
      constraints min: 0, max: 20
      public? true
    end

    attribute :next_attempt_at, :utc_datetime_usec do
      public? true
    end

    attribute :apply_job_id, :integer do
      public? true
    end

    attribute :evaluated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :catalog_sync_run, EventSales.Ingestion.Resources.TickeraCatalogSyncRun do
      allow_nil? false
      public? true
    end

    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :decision_identity, [:catalog_sync_run_id, :dry_run_hash, :policy_version]
  end

  def copy_locked_run_source(changeset, _context) do
    run_id = Ash.Changeset.get_attribute(changeset, :catalog_sync_run_id)

    source_system_id =
      EventSales.Repo.one!(
        from run in "ingestion_tickera_catalog_sync_runs",
          where: run.id == type(^run_id, :binary_id),
          lock: "FOR UPDATE",
          select: run.source_system_id
      )

    Ash.Changeset.force_change_attribute(changeset, :source_system_id, source_system_id)
  end

  def set_evaluated_at(changeset, _context) do
    Ash.Changeset.force_change_attribute(changeset, :evaluated_at, DateTime.utc_now())
  end

  @action_summary_keys ~w(event_create event_reuse ticket_type_create ticket_type_reuse product_mapping_create total)
  @finding_summary_keys ~w(total info warning blocking unknown)
  @historical_summary_keys ~w(affected_pending_lines affected_quantity eligible_lines deferred_lines conflicting_lines already_mapped_lines warning_count unresolved_destination_count unknown_classification_count)

  def validate_closed_summaries(changeset, _context) do
    [
      {:action_summary, @action_summary_keys, 1_024},
      {:finding_summary, @finding_summary_keys, 1_024},
      {:historical_summary, @historical_summary_keys, 2_048}
    ]
    |> Enum.reduce(changeset, fn {attribute, keys, max_bytes}, changeset ->
      value = Ash.Changeset.get_attribute(changeset, attribute)

      if valid_summary?(value, keys, max_bytes) do
        changeset
      else
        Ash.Changeset.add_error(changeset,
          field: attribute,
          message: "must match the closed bounded summary schema"
        )
      end
    end)
  end

  defp valid_summary?(value, keys, max_bytes) when is_map(value) do
    normalized_keys = value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    normalized_keys == Enum.sort(keys) and
      Enum.all?(value, fn {_key, count} -> is_integer(count) and count >= 0 end) and
      byte_size(Jason.encode!(value)) <= max_bytes
  end

  defp valid_summary?(_value, _keys, _max_bytes), do: false
end
