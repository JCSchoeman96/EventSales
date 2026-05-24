defmodule EventSales.Ingestion.Resources.WebhookEvent do
  @moduledoc """
  Received WooCommerce webhook delivery for idempotency, replay, and troubleshooting.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  @statuses [:queued, :processing, :processed, :failed, :ignored, :buffered]
  @accepted_via_values [:postgres, :redis_buffer]
  @ignore_reasons [
    :unsupported_topic,
    :stale_source_version,
    :duplicate_resource_hash,
    :unknown_product
  ]

  postgres do
    table "ingestion_webhook_events"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :status, name: "ingestion_webhook_events_status_idx"
      index :received_at, name: "ingestion_webhook_events_received_at_idx"

      index [:source_system_id, :resource_type, :resource_id, :source_updated_at],
        name: "ingestion_webhook_events_resource_source_updated_at_idx"

      index [:source_system_id, :resource_type, :resource_id, :payload_hash],
        name: "ingestion_webhook_events_resource_payload_hash_idx"
    end
  end

  actions do
    defaults [:read]

    create :receive do
      accept [
        :source_system_id,
        :topic,
        :resource_type,
        :resource_id,
        :delivery_id,
        :payload,
        :payload_hash,
        :raw_body_size,
        :signature_validated_at,
        :received_at,
        :source_updated_at,
        :sanitized_headers_snapshot,
        :accepted_via
      ]

      validate present([
                 :topic,
                 :resource_type,
                 :resource_id,
                 :delivery_id,
                 :payload,
                 :payload_hash
               ])

      change set_attribute(:status, :queued)
    end

    update :mark_processing do
      accept [:processing_attempt_count, :processing_started_at]
      change set_attribute(:status, :processing)
    end

    update :mark_processed do
      accept [:processed_at, :failed_at, :error_message, :ignore_reason]
      change set_attribute(:status, :processed)
    end

    update :mark_failed do
      accept [:failed_at, :error_message]
      change set_attribute(:status, :failed)
    end

    update :mark_retryable do
      accept [:error_message]
      change set_attribute(:status, :queued)
    end

    update :queue_for_replay do
      accept [:failed_at, :error_message, :ignore_reason, :processed_at, :processing_started_at]
      change set_attribute(:status, :queued)
    end

    update :mark_ignored do
      accept [:ignore_reason, :processed_at]
      validate present([:ignore_reason])
      change set_attribute(:status, :ignored)
    end

    update :redact_payload do
      accept [:payload]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :topic, :string do
      allow_nil? false
      public? true
    end

    attribute :resource_type, :string do
      allow_nil? false
      public? true
    end

    attribute :resource_id, :string do
      allow_nil? false
      public? true
    end

    attribute :delivery_id, :string do
      allow_nil? false
      public? true
    end

    attribute :payload, :map do
      allow_nil? false
      public? true
    end

    attribute :payload_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued
      constraints one_of: @statuses
      public? true
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :signature_validated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :raw_body_size, :integer do
      allow_nil? false
      public? true
    end

    attribute :accepted_via, :atom do
      allow_nil? false
      default :postgres
      constraints one_of: @accepted_via_values
      public? true
    end

    attribute :source_updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :processing_started_at, :utc_datetime_usec do
      public? true
    end

    attribute :processed_at, :utc_datetime_usec do
      public? true
    end

    attribute :failed_at, :utc_datetime_usec do
      public? true
    end

    attribute :error_message, :string do
      public? true
    end

    attribute :ignore_reason, :atom do
      constraints one_of: @ignore_reasons
      public? true
    end

    attribute :processing_attempt_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :sanitized_headers_snapshot, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_delivery_id, [:delivery_id]
  end
end
