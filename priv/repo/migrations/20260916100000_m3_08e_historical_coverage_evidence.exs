defmodule EventSales.Repo.Migrations.M308eHistoricalCoverageEvidence do
  use Ecto.Migration

  def up do
    alter table(:ingestion_sync_runs) do
      add :coverage_evidence, :map, null: false, default: %{}
    end
  end

  def down do
    alter table(:ingestion_sync_runs) do
      remove :coverage_evidence
    end
  end
end
