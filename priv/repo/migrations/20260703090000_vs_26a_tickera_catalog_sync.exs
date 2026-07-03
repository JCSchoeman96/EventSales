defmodule EventSales.Repo.Migrations.Vs26aTickeraCatalogSync do
  use Ecto.Migration

  def up do
    alter table(:catalog_events) do
      add :external_event_id, :bigint
      add :external_event_kind, :text
      add :source_status, :text
      add :source_updated_at, :utc_datetime_usec
      add :last_synced_at, :utc_datetime_usec
    end

    create unique_index(
             :catalog_events,
             [:source_system_id, :external_event_kind, :external_event_id],
             name: "catalog_events_unique_external_tickera_event_idx",
             where: "external_event_kind IS NOT NULL AND external_event_id IS NOT NULL"
           )

    alter table(:catalog_ticket_types) do
      add :external_ticket_type_id, :bigint
      add :external_ticket_type_kind, :text
      add :external_product_id, :bigint
      add :external_variation_id, :bigint
      add :source_status, :text
      add :source_updated_at, :utc_datetime_usec
      add :last_synced_at, :utc_datetime_usec
    end

    create unique_index(
             :catalog_ticket_types,
             [:event_id, :external_ticket_type_kind, :external_ticket_type_id],
             name: "catalog_ticket_types_unique_external_ticket_idx",
             where:
               "external_ticket_type_kind IS NOT NULL AND external_ticket_type_id IS NOT NULL"
           )

    create index(:catalog_ticket_types, [:external_product_id],
             name: "catalog_ticket_types_external_product_id_idx"
           )

    create index(:catalog_ticket_types, [:external_variation_id],
             name: "catalog_ticket_types_external_variation_id_idx"
           )

    create index(:catalog_ticket_types, [:event_id, :active],
             name: "catalog_ticket_types_event_active_idx"
           )

    create table(:ingestion_tickera_catalog_sync_runs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :scope, :map, null: false, default: %{}
      add :status, :text, null: false, default: "queued"
      add :dry_run_hash, :text
      add :summary, :map, null: false, default: %{}
      add :plan_snapshot, :map
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :last_error, :text

      add :source_system_id,
          references(:catalog_source_systems,
            column: :id,
            name: "ingestion_tickera_catalog_sync_runs_source_system_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict,
            on_update: :update_all
          ),
          null: false

      add :requested_by_user_id,
          references(:accounts_users,
            column: :id,
            name: "ingestion_tickera_catalog_sync_runs_requested_by_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all,
            on_update: :update_all
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:ingestion_tickera_catalog_sync_runs, [:source_system_id, :status],
             name: "ingestion_tickera_catalog_sync_runs_source_status_idx"
           )

    create index(:ingestion_tickera_catalog_sync_runs, [:source_system_id, :inserted_at],
             name: "ingestion_tickera_catalog_sync_runs_source_inserted_at_idx"
           )

    create index(:ingestion_tickera_catalog_sync_runs, [:dry_run_hash],
             name: "ingestion_tickera_catalog_sync_runs_hash_idx"
           )

    create table(:ingestion_tickera_catalog_sync_findings, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :severity, :text, null: false
      add :code, :text, null: false
      add :message, :text, null: false
      add :tickera_event_id, :bigint
      add :woo_product_id, :bigint
      add :woo_variation_id, :bigint
      add :metadata, :map, null: false, default: %{}

      add :run_id,
          references(:ingestion_tickera_catalog_sync_runs,
            column: :id,
            name: "ingestion_tickera_catalog_sync_findings_run_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all,
            on_update: :update_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:ingestion_tickera_catalog_sync_findings, [:run_id, :severity],
             name: "ingestion_tickera_catalog_sync_findings_run_severity_idx"
           )

    create index(:ingestion_tickera_catalog_sync_findings, [:code],
             name: "ingestion_tickera_catalog_sync_findings_code_idx"
           )

    create index(:ingestion_tickera_catalog_sync_findings, [:tickera_event_id],
             name: "ingestion_tickera_catalog_sync_findings_event_idx"
           )

    create index(:ingestion_tickera_catalog_sync_findings, [:woo_product_id, :woo_variation_id],
             name: "ingestion_tickera_catalog_sync_findings_product_variation_idx"
           )
  end

  def down do
    drop_if_exists index(
                     :ingestion_tickera_catalog_sync_findings,
                     [
                       :woo_product_id,
                       :woo_variation_id
                     ],
                     name: "ingestion_tickera_catalog_sync_findings_product_variation_idx"
                   )

    drop_if_exists index(:ingestion_tickera_catalog_sync_findings, [:tickera_event_id],
                     name: "ingestion_tickera_catalog_sync_findings_event_idx"
                   )

    drop_if_exists index(:ingestion_tickera_catalog_sync_findings, [:code],
                     name: "ingestion_tickera_catalog_sync_findings_code_idx"
                   )

    drop_if_exists index(:ingestion_tickera_catalog_sync_findings, [:run_id, :severity],
                     name: "ingestion_tickera_catalog_sync_findings_run_severity_idx"
                   )

    drop table(:ingestion_tickera_catalog_sync_findings)

    drop_if_exists index(:ingestion_tickera_catalog_sync_runs, [:dry_run_hash],
                     name: "ingestion_tickera_catalog_sync_runs_hash_idx"
                   )

    drop_if_exists index(:ingestion_tickera_catalog_sync_runs, [:source_system_id, :inserted_at],
                     name: "ingestion_tickera_catalog_sync_runs_source_inserted_at_idx"
                   )

    drop_if_exists index(:ingestion_tickera_catalog_sync_runs, [:source_system_id, :status],
                     name: "ingestion_tickera_catalog_sync_runs_source_status_idx"
                   )

    drop table(:ingestion_tickera_catalog_sync_runs)

    drop_if_exists index(:catalog_ticket_types, [:event_id, :active],
                     name: "catalog_ticket_types_event_active_idx"
                   )

    drop_if_exists index(:catalog_ticket_types, [:external_variation_id],
                     name: "catalog_ticket_types_external_variation_id_idx"
                   )

    drop_if_exists index(:catalog_ticket_types, [:external_product_id],
                     name: "catalog_ticket_types_external_product_id_idx"
                   )

    drop_if_exists unique_index(
                     :catalog_ticket_types,
                     [:event_id, :external_ticket_type_kind, :external_ticket_type_id],
                     name: "catalog_ticket_types_unique_external_ticket_idx"
                   )

    alter table(:catalog_ticket_types) do
      remove :last_synced_at
      remove :source_updated_at
      remove :source_status
      remove :external_variation_id
      remove :external_product_id
      remove :external_ticket_type_kind
      remove :external_ticket_type_id
    end

    drop_if_exists unique_index(
                     :catalog_events,
                     [:source_system_id, :external_event_kind, :external_event_id],
                     name: "catalog_events_unique_external_tickera_event_idx"
                   )

    alter table(:catalog_events) do
      remove :last_synced_at
      remove :source_updated_at
      remove :source_status
      remove :external_event_kind
      remove :external_event_id
    end
  end
end
