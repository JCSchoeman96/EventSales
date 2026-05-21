defmodule EventSales.Ingestion.Resources.CsvImportBatch do
  @moduledoc """
  Event-scoped CSV import dry-run batch.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion,
    extensions: [AshStateMachine]

  @statuses [:uploaded, :validating, :dry_run_passed, :dry_run_failed, :failed]

  postgres do
    table "ingestion_csv_import_batches"
    repo EventSales.Repo

    references do
      reference :event, on_delete: :restrict, on_update: :update
      reference :uploaded_by_user, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :event_id, name: "ingestion_csv_import_batches_event_id_idx"
      index :status, name: "ingestion_csv_import_batches_status_idx"
      index :uploaded_by_user_id, name: "ingestion_csv_import_batches_uploaded_by_user_id_idx"
      index :inserted_at, name: "ingestion_csv_import_batches_inserted_at_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_dry_run do
      accept [:event_id, :uploaded_by_user_id, :source_filename]
      validate present([:event_id, :uploaded_by_user_id, :source_filename])
      change set_attribute(:status, :uploaded)
    end

    update :mark_validating do
      require_atomic? false
      change transition_state(:validating)
    end

    update :mark_dry_run_passed do
      accept [:row_count, :valid_count, :error_count, :duplicate_count]
      require_atomic? false
      change transition_state(:dry_run_passed)
    end

    update :mark_dry_run_failed do
      accept [:row_count, :valid_count, :error_count, :duplicate_count, :last_error]
      require_atomic? false
      change transition_state(:dry_run_failed)
    end

    update :mark_failed do
      accept [:last_error]
      require_atomic? false
      change transition_state(:failed)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source_filename, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :uploaded
      constraints one_of: @statuses
      public? true
    end

    attribute :row_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :valid_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :error_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :duplicate_count, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    belongs_to :uploaded_by_user, EventSales.Accounts.Resources.User do
      allow_nil? false
      public? true
    end

    has_many :rows, EventSales.Ingestion.Resources.CsvImportRow do
      destination_attribute :csv_import_batch_id
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:uploaded]
    default_initial_state :uploaded

    transitions do
      transition :mark_validating, from: :uploaded, to: :validating
      transition :mark_dry_run_passed, from: :validating, to: :dry_run_passed
      transition :mark_dry_run_failed, from: :validating, to: :dry_run_failed
      transition :mark_failed, from: [:uploaded, :validating], to: :failed
    end
  end
end
