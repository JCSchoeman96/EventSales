defmodule EventSales.Ingestion.Resources.CsvImportRow do
  @moduledoc """
  Row-level CSV import dry-run validation result.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  @statuses [:valid, :invalid, :duplicate, :skipped]

  postgres do
    table "ingestion_csv_import_rows"
    repo EventSales.Repo

    references do
      reference :csv_import_batch, on_delete: :delete, on_update: :update
    end

    custom_indexes do
      index :csv_import_batch_id, name: "ingestion_csv_import_rows_batch_id_idx"
      index :status, name: "ingestion_csv_import_rows_status_idx"
      index :external_order_number, name: "ingestion_csv_import_rows_external_order_number_idx"
      index :external_line_key, name: "ingestion_csv_import_rows_external_line_key_idx"

      index [:csv_import_batch_id, :row_number],
        unique: true,
        name: "ingestion_csv_import_rows_unique_batch_row_idx"
    end
  end

  actions do
    defaults [:read]

    create :store_validation_result do
      accept [
        :csv_import_batch_id,
        :row_number,
        :raw_data,
        :normalized_data,
        :status,
        :error_messages,
        :external_order_number,
        :external_line_key
      ]

      validate present([:csv_import_batch_id, :row_number, :status])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :row_number, :integer do
      allow_nil? false
      constraints min: 2
      public? true
    end

    attribute :raw_data, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :normalized_data, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: @statuses
      public? true
    end

    attribute :error_messages, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :external_order_number, :string do
      public? true
    end

    attribute :external_line_key, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :csv_import_batch, EventSales.Ingestion.Resources.CsvImportBatch do
      allow_nil? false
      public? true
    end
  end
end
