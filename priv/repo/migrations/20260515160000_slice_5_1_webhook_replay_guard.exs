defmodule EventSales.Repo.Migrations.Slice51WebhookReplayGuard do
  use Ecto.Migration

  def up do
    alter table(:ingestion_webhook_events) do
      add :source_updated_at, :utc_datetime_usec
      add :sanitized_headers_snapshot, :map, null: false, default: %{}
    end

    create index(
             :ingestion_webhook_events,
             [:source_system_id, :resource_type, :resource_id, :source_updated_at],
             name: "ingestion_webhook_events_resource_source_updated_at_idx"
           )
  end

  def down do
    drop_if_exists index(
                     :ingestion_webhook_events,
                     [:source_system_id, :resource_type, :resource_id, :source_updated_at],
                     name: "ingestion_webhook_events_resource_source_updated_at_idx"
                   )

    alter table(:ingestion_webhook_events) do
      remove :sanitized_headers_snapshot
      remove :source_updated_at
    end
  end
end
