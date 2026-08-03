defmodule EventSales.Repo.Migrations.AddMappingResolutionCancellationReason do
  use Ecto.Migration

  @constraint "catalog_sync_runs_cancel_reason_check"

  def up do
    drop constraint(:ingestion_tickera_catalog_sync_runs, @constraint)

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             @constraint,
             check:
               "cancellation_reason_code IS NULL OR cancellation_reason_code IN ('source_changed', 'incorrect_scope', 'unexpected_changes', 'superseded', 'operator_error', 'mapping_resolution_started', 'other')"
           )
  end

  def down do
    drop constraint(:ingestion_tickera_catalog_sync_runs, @constraint)

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             @constraint,
             check:
               "cancellation_reason_code IS NULL OR cancellation_reason_code IN ('source_changed', 'incorrect_scope', 'unexpected_changes', 'superseded', 'operator_error', 'other')"
           )
  end
end
