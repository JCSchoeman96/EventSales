defmodule EventSales.Repo.Migrations.Slice14ReconciliationSyncCursors do
  @moduledoc """
  Creates ingestion_sync_cursors for per-run REST reconciliation progress.
  """

  use Ecto.Migration

  def up do
    create table(:ingestion_sync_cursors, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :page, :bigint, null: false, default: 1
      add :modified_after, :utc_datetime_usec
      add :modified_before, :utc_datetime_usec
      add :last_seen_order_id, :bigint
      add :status, :text, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :sync_run_id,
          references(:ingestion_sync_runs,
            column: :id,
            name: "ingestion_sync_cursors_sync_run_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all,
            on_update: :update_all
          ),
          null: false
    end

    create unique_index(:ingestion_sync_cursors, [:sync_run_id],
             name: "ingestion_sync_cursors_sync_run_id_idx"
           )

    create index(:ingestion_sync_cursors, [:status], name: "ingestion_sync_cursors_status_idx")

    create index(:ingestion_sync_cursors, [:modified_after],
             name: "ingestion_sync_cursors_modified_after_idx"
           )
  end

  def down do
    drop constraint(:ingestion_sync_cursors, "ingestion_sync_cursors_sync_run_id_fkey")

    drop_if_exists index(:ingestion_sync_cursors, [:modified_after],
                     name: "ingestion_sync_cursors_modified_after_idx"
                   )

    drop_if_exists index(:ingestion_sync_cursors, [:status],
                     name: "ingestion_sync_cursors_status_idx"
                   )

    drop_if_exists unique_index(:ingestion_sync_cursors, [:sync_run_id],
                     name: "ingestion_sync_cursors_sync_run_id_idx"
                   )

    drop table(:ingestion_sync_cursors)
  end
end
