defmodule EventSales.Repo.Migrations.Slice6WebhookEventLifecycle do
  use Ecto.Migration

  def up do
    alter table(:ingestion_webhook_events) do
      add :processing_started_at, :utc_datetime_usec
      add :processed_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :error_message, :text
      add :ignore_reason, :text
      add :processing_attempt_count, :bigint, null: false, default: 0
    end

    create index(
             :ingestion_webhook_events,
             [:source_system_id, :resource_type, :resource_id, :payload_hash],
             name: "ingestion_webhook_events_resource_payload_hash_idx"
           )
  end

  def down do
    drop_if_exists index(
                     :ingestion_webhook_events,
                     [:source_system_id, :resource_type, :resource_id, :payload_hash],
                     name: "ingestion_webhook_events_resource_payload_hash_idx"
                   )

    alter table(:ingestion_webhook_events) do
      remove :processing_attempt_count
      remove :ignore_reason
      remove :error_message
      remove :failed_at
      remove :processed_at
      remove :processing_started_at
    end
  end
end
