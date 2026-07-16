defmodule EventSales.Repo.Migrations.AddCatalogSyncRetryMetadata do
  use Ecto.Migration

  def change do
    alter table(:ingestion_tickera_catalog_sync_runs) do
      add :retry_attempt, :integer
      add :retry_max_attempts, :integer
    end

    create constraint(:ingestion_tickera_catalog_sync_runs, :catalog_sync_retry_attempt_bounds,
             check: "retry_attempt IS NULL OR retry_attempt BETWEEN 1 AND 100"
           )

    create constraint(
             :ingestion_tickera_catalog_sync_runs,
             :catalog_sync_retry_max_attempts_bounds,
             check: "retry_max_attempts IS NULL OR retry_max_attempts BETWEEN 1 AND 100"
           )

    create constraint(:ingestion_tickera_catalog_sync_runs, :catalog_sync_last_error_bounds,
             check: "last_error IS NULL OR char_length(last_error) <= 120"
           )
  end
end
