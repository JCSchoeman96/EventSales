defmodule EventSales.Ingestion.Resources.WebhookEvent do
  @moduledoc """
  Received WooCommerce webhook delivery for idempotency, replay, and troubleshooting.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  @statuses [:queued, :processing, :processed, :failed, :ignored, :buffered]
  @accepted_via_values [:postgres, :redis_buffer]

  postgres do
    table "ingestion_webhook_events"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :delivery_id, unique: true, name: "ingestion_webhook_events_delivery_id_idx"
      index :status, name: "ingestion_webhook_events_status_idx"
      index :received_at, name: "ingestion_webhook_events_received_at_idx"
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
        :received_at
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
      change set_attribute(:accepted_via, :postgres)
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
