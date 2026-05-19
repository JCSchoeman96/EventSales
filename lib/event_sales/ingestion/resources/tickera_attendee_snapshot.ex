defmodule EventSales.Ingestion.Resources.TickeraAttendeeSnapshot do
  @moduledoc """
  Durable normalized Tickera attendee snapshot for later reconciliation.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.Validations.AuthorizedTickeraStateMutation

  @upsert_accept [
    :tickera_event_source_id,
    :tickera_attendee_sync_run_id,
    :source_system_id,
    :event_id,
    :ticket_code,
    :checksum,
    :ticket_type_id,
    :ticket_type,
    :first_name,
    :last_name,
    :email,
    :buyer_first,
    :buyer_last,
    :buyer_email,
    :allowed_checkins,
    :used_checkins,
    :remaining_checkins,
    :checked_in,
    :payment_status,
    :payment_date_raw,
    :custom_fields,
    :raw_source_hash,
    :source_updated_at,
    :last_seen_at
  ]

  postgres do
    table "ingestion_tickera_attendee_snapshots"
    repo EventSales.Repo

    references do
      reference :tickera_event_source, on_delete: :restrict, on_update: :update
      reference :tickera_attendee_sync_run, on_delete: :nilify, on_update: :update
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :event_id, name: "ingestion_tickera_attendee_snapshots_event_id_idx"
      index :source_system_id, name: "ingestion_tickera_attendee_snapshots_source_system_id_idx"
      index :ticket_code, name: "ingestion_tickera_attendee_snapshots_ticket_code_idx"
      index :checksum, name: "ingestion_tickera_attendee_snapshots_checksum_idx"
      index :ticket_type_id, name: "ingestion_tickera_attendee_snapshots_ticket_type_id_idx"
      index :payment_status, name: "ingestion_tickera_attendee_snapshots_payment_status_idx"
      index :last_seen_at, name: "ingestion_tickera_attendee_snapshots_last_seen_at_idx"

      index [:event_id, :ticket_type_id],
        name: "ingestion_tickera_attendee_snapshots_event_ticket_type_idx"

      index [:tickera_event_source_id, :ticket_type_id],
        name: "ingestion_tickera_attendee_snapshots_source_ticket_type_idx"

      index [:tickera_event_source_id, :payment_status],
        name: "ingestion_tickera_attendee_snapshots_source_payment_idx"
    end

    identity_index_names unique_source_ticket_code:
                           "tickera_attendee_snapshots_source_ticket_code_idx"
  end

  actions do
    defaults [:read]

    create :upsert_from_tickera do
      accept @upsert_accept
      argument :checked_in?, :boolean
      upsert? true
      upsert_identity :unique_source_ticket_code
      upsert_fields @upsert_accept
      validate {AuthorizedTickeraStateMutation, []}

      validate present([
                 :tickera_event_source_id,
                 :source_system_id,
                 :event_id,
                 :ticket_code,
                 :raw_source_hash,
                 :last_seen_at
               ])

      change &__MODULE__.normalize_snapshot/2
    end

    update :mark_seen do
      require_atomic? false
      accept [:tickera_attendee_sync_run_id, :raw_source_hash, :source_updated_at, :last_seen_at]
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:raw_source_hash, :last_seen_at])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ticket_code, :string do
      allow_nil? false
      public? true
    end

    attribute :checksum, :string do
      public? true
    end

    attribute :ticket_type_id, :integer do
      constraints min: 1
      public? true
    end

    attribute :ticket_type, :string do
      public? true
    end

    attribute :first_name, :string do
      public? true
    end

    attribute :last_name, :string do
      public? true
    end

    attribute :email, :string do
      public? true
    end

    attribute :buyer_first, :string do
      public? true
    end

    attribute :buyer_last, :string do
      public? true
    end

    attribute :buyer_email, :string do
      public? true
    end

    attribute :allowed_checkins, :integer do
      constraints min: 0
      public? true
    end

    attribute :used_checkins, :integer do
      constraints min: 0
      public? true
    end

    attribute :remaining_checkins, :integer do
      constraints min: 0
      public? true
    end

    attribute :checked_in, :boolean do
      public? true
    end

    attribute :payment_status, :string do
      public? true
    end

    attribute :payment_date_raw, :string do
      public? true
    end

    attribute :custom_fields, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :raw_source_hash, :string do
      allow_nil? false
      public? true
    end

    attribute :source_updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tickera_event_source, EventSales.Ingestion.Resources.TickeraEventSource do
      allow_nil? false
      public? true
    end

    belongs_to :tickera_attendee_sync_run,
               EventSales.Ingestion.Resources.TickeraAttendeeSyncRun do
      public? true
    end

    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end

    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_source_ticket_code, [:tickera_event_source_id, :ticket_code]
  end

  def normalize_snapshot(changeset, _context) do
    changeset
    |> copy_checked_in_argument()
    |> normalize_string_fields()
    |> validate_required_strings()
    |> validate_custom_fields()
  end

  defp copy_checked_in_argument(changeset) do
    case Ash.Changeset.get_argument(changeset, :checked_in?) do
      nil -> changeset
      value -> Ash.Changeset.force_change_attribute(changeset, :checked_in, value)
    end
  end

  defp normalize_string_fields(changeset) do
    Enum.reduce(string_fields(), changeset, fn field, changeset ->
      case Ash.Changeset.get_attribute(changeset, field) do
        nil ->
          changeset

        value when is_binary(value) ->
          normalized = value |> String.trim() |> maybe_downcase(field)
          Ash.Changeset.force_change_attribute(changeset, field, normalized)
      end
    end)
  end

  defp string_fields do
    [
      :ticket_code,
      :checksum,
      :ticket_type,
      :first_name,
      :last_name,
      :email,
      :buyer_first,
      :buyer_last,
      :buyer_email,
      :payment_status,
      :payment_date_raw,
      :raw_source_hash
    ]
  end

  defp maybe_downcase(value, field) when field in [:email, :buyer_email],
    do: String.downcase(value)

  defp maybe_downcase(value, _field), do: value

  defp validate_required_strings(changeset) do
    Enum.reduce([:ticket_code, :raw_source_hash], changeset, fn field, changeset ->
      case Ash.Changeset.get_attribute(changeset, field) do
        value when is_binary(value) and value != "" -> changeset
        _other -> Ash.Changeset.add_error(changeset, field: field, message: "must not be blank")
      end
    end)
  end

  defp validate_custom_fields(changeset) do
    case Ash.Changeset.get_attribute(changeset, :custom_fields) do
      value when is_map(value) ->
        changeset

      _other ->
        Ash.Changeset.add_error(changeset, field: :custom_fields, message: "must be a map")
    end
  end
end
