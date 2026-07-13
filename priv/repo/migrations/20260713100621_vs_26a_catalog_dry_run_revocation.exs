defmodule EventSales.Repo.Migrations.Vs26aCatalogDryRunRevocation do
  use Ecto.Migration

  def up do
    alter table(:ingestion_tickera_catalog_sync_runs) do
      add :cancelled_at, :utc_datetime_usec

      add :cancelled_by_user_id,
          references(:accounts_users,
            column: :id,
            name: "catalog_sync_runs_cancelled_by_user_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict,
            on_update: :update_all
          )

      add :cancellation_reason_code, :text
      add :cancellation_reason_details, :text
    end

    create index(:ingestion_tickera_catalog_sync_runs, [:cancelled_by_user_id],
             name: "catalog_sync_runs_cancelled_by_user_idx"
           )

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             :catalog_sync_runs_cancel_reason_check,
             check:
               "cancellation_reason_code IS NULL OR cancellation_reason_code IN ('source_changed', 'incorrect_scope', 'unexpected_changes', 'superseded', 'operator_error', 'other')"
           )

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             :catalog_sync_runs_cancel_details_len_check,
             check:
               "cancellation_reason_details IS NULL OR char_length(cancellation_reason_details) <= 500"
           )

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             :catalog_sync_runs_other_details_check,
             check:
               "cancellation_reason_code <> 'other' OR length(btrim(coalesce(cancellation_reason_details, ''))) > 0"
           )

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             :catalog_sync_runs_cancel_audit_check,
             check: """
             (status = 'cancelled' AND cancelled_at IS NOT NULL AND cancelled_by_user_id IS NOT NULL AND cancellation_reason_code IS NOT NULL)
             OR
             (status <> 'cancelled' AND cancelled_at IS NULL AND cancelled_by_user_id IS NULL AND cancellation_reason_code IS NULL AND cancellation_reason_details IS NULL)
             """
           )
  end

  def down do
    drop constraint(
           :ingestion_tickera_catalog_sync_runs,
           :catalog_sync_runs_cancel_audit_check
         )

    drop constraint(
           :ingestion_tickera_catalog_sync_runs,
           :catalog_sync_runs_other_details_check
         )

    drop constraint(
           :ingestion_tickera_catalog_sync_runs,
           :catalog_sync_runs_cancel_details_len_check
         )

    drop constraint(
           :ingestion_tickera_catalog_sync_runs,
           :catalog_sync_runs_cancel_reason_check
         )

    drop_if_exists index(:ingestion_tickera_catalog_sync_runs, [:cancelled_by_user_id],
                     name: "catalog_sync_runs_cancelled_by_user_idx"
                   )

    drop constraint(
           :ingestion_tickera_catalog_sync_runs,
           "catalog_sync_runs_cancelled_by_user_fkey"
         )

    alter table(:ingestion_tickera_catalog_sync_runs) do
      remove :cancellation_reason_details
      remove :cancellation_reason_code
      remove :cancelled_by_user_id
      remove :cancelled_at
    end
  end
end
