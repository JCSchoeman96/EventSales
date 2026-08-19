defmodule EventSales.Repo.Migrations.M308aHistoricalCoverageWatermark do
  use Ecto.Migration

  def up do
    alter table(:ingestion_sync_runs) do
      add :coverage_start, :utc_datetime_usec
      add :sales_covered_through, :utc_datetime_usec
      add :refunds_covered_through, :utc_datetime_usec
      add :order_coverage_status, :text, null: false, default: "incomplete"
      add :refund_coverage_status, :text, null: false, default: "not_started"
      add :coverage_certified_at, :utc_datetime_usec
      add :coverage_invalidated_at, :utc_datetime_usec
      add :coverage_invalidation_reason, :text
    end
  end

  def down do
    alter table(:ingestion_sync_runs) do
      remove :coverage_invalidation_reason
      remove :coverage_invalidated_at
      remove :coverage_certified_at
      remove :refund_coverage_status
      remove :order_coverage_status
      remove :refunds_covered_through
      remove :sales_covered_through
      remove :coverage_start
    end
  end
end
