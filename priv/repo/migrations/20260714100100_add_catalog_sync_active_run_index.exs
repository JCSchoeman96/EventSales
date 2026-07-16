defmodule EventSales.Repo.Migrations.AddCatalogSyncActiveRunIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  @index_name "ingestion_tickera_catalog_sync_runs_one_active_per_source_idx"
  @active_statuses "'queued', 'discovering', 'retry_scheduled', 'dry_run_ready', 'applying'"

  def up do
    execute("""
    DO $$
    DECLARE duplicate_sources text;
    BEGIN
      SELECT string_agg(source_system_id::text || ':' || active_count::text, ', ')
      INTO duplicate_sources
      FROM (
        SELECT source_system_id, count(*) AS active_count
        FROM ingestion_tickera_catalog_sync_runs
        WHERE status IN (#{@active_statuses})
        GROUP BY source_system_id
        HAVING count(*) > 1
        ORDER BY source_system_id
        LIMIT 20
      ) duplicates;

      IF duplicate_sources IS NOT NULL THEN
        RAISE EXCEPTION 'catalog sync active-run duplicates: %', duplicate_sources;
      END IF;
    END $$;
    """)

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY #{@index_name}
    ON ingestion_tickera_catalog_sync_runs (source_system_id)
    WHERE status IN (#{@active_statuses})
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}")
  end
end
