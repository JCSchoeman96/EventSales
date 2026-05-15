defmodule EventSales.Ingestion.Resources.WebhookDeliveryFailure do
  @moduledoc """
  Minimal metadata for rejected webhook attempts without storing unsafe raw bodies.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.Validations.BoundedMetadata

  @reasons [
    :invalid_signature,
    :wrong_path_token,
    :invalid_json,
    :no_source_system,
    :enqueue_failed,
    :stale_replay,
    :duplicate_payload_mismatch
  ]

  @metadata_max_bytes 2048

  postgres do
    table "ingestion_webhook_delivery_failures"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :nilify, on_update: :update
    end

    custom_indexes do
      index :reason, name: "ingestion_webhook_delivery_failures_reason_idx"
      index :received_at, name: "ingestion_webhook_delivery_failures_received_at_idx"
    end
  end

  actions do
    defaults [:read]

    create :log_failure do
      accept [
        :reason,
        :topic,
        :remote_ip_hash,
        :user_agent_hash,
        :metadata,
        :received_at,
        :source_system_id
      ]

      validate present(:reason)
      validate {BoundedMetadata, max_bytes: @metadata_max_bytes}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :reason, :atom do
      allow_nil? false
      constraints one_of: @reasons
      public? true
    end

    attribute :topic, :string do
      public? true
    end

    attribute :remote_ip_hash, :string do
      public? true
    end

    attribute :user_agent_hash, :string do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      public? true
    end
  end
end
