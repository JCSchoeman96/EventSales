defmodule EventSales.Ingestion.Resources.TickeraEventSource do
  @moduledoc """
  Event-scoped Tickera attendee feed configuration.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.Validations.AuthorizedTickeraStateMutation

  @default_site_url "https://voelgoed.co.za"
  @create_update_accept [
    :source_system_id,
    :event_id,
    :tickera_site_url,
    :api_key_env_var,
    :api_key_last4,
    :active,
    :notes
  ]

  postgres do
    table "ingestion_tickera_event_sources"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :event_id, name: "ingestion_tickera_event_sources_event_id_idx"
      index :source_system_id, name: "ingestion_tickera_event_sources_source_system_id_idx"
      index :active, name: "ingestion_tickera_event_sources_active_idx"
      index :api_key_env_var, name: "ingestion_tickera_event_sources_api_key_env_var_idx"
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept @create_update_accept
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:source_system_id, :event_id, :tickera_site_url, :api_key_env_var])
      change &__MODULE__.normalize_config/2
    end

    update :update do
      accept @create_update_accept
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      validate present([:source_system_id, :event_id, :tickera_site_url, :api_key_env_var])
      change &__MODULE__.normalize_config/2
    end

    update :activate do
      accept []
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change set_attribute(:active, true)
    end

    update :deactivate do
      accept []
      require_atomic? false
      validate {AuthorizedTickeraStateMutation, []}
      change set_attribute(:active, false)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tickera_site_url, :string do
      allow_nil? false
      default @default_site_url
      public? true
    end

    attribute :api_key_env_var, :string do
      allow_nil? false
      public? true
    end

    attribute :api_key_last4, :string do
      public? true
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :notes, :string do
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

    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    has_many :sync_runs, EventSales.Ingestion.Resources.TickeraAttendeeSyncRun do
      destination_attribute :tickera_event_source_id
    end

    has_many :attendee_snapshots, EventSales.Ingestion.Resources.TickeraAttendeeSnapshot do
      destination_attribute :tickera_event_source_id
    end
  end

  identities do
    identity :unique_source_event, [:source_system_id, :event_id]
  end

  validations do
    validate attribute_does_not_equal(:tickera_site_url, "") do
      on [:create, :update]
    end
  end

  def normalize_config(changeset, _context) do
    changeset
    |> normalize_site_url()
    |> normalize_api_key_env_var()
    |> normalize_api_key_last4()
  end

  defp normalize_site_url(changeset) do
    case Ash.Changeset.get_attribute(changeset, :tickera_site_url) do
      nil ->
        changeset

      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> add_default_scheme()
          |> String.trim_trailing("/")

        changeset = Ash.Changeset.force_change_attribute(changeset, :tickera_site_url, normalized)

        cond do
          normalized == "" ->
            Ash.Changeset.add_error(changeset,
              field: :tickera_site_url,
              message: "must not be blank"
            )

          app_env() == :prod and String.starts_with?(normalized, "http://") ->
            Ash.Changeset.add_error(changeset,
              field: :tickera_site_url,
              message: "must use https in prod"
            )

          true ->
            changeset
        end
    end
  end

  defp add_default_scheme(""), do: ""

  defp add_default_scheme(value) do
    if String.starts_with?(value, ["http://", "https://"]) do
      value
    else
      "https://" <> value
    end
  end

  defp normalize_api_key_env_var(changeset) do
    case Ash.Changeset.get_attribute(changeset, :api_key_env_var) do
      value when is_binary(value) ->
        normalized = String.trim(value)
        changeset = Ash.Changeset.force_change_attribute(changeset, :api_key_env_var, normalized)

        if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, normalized) do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :api_key_env_var,
            message: "must be a safe env var name"
          )
        end

      _other ->
        changeset
    end
  end

  defp normalize_api_key_last4(changeset) do
    case Ash.Changeset.get_attribute(changeset, :api_key_last4) do
      nil ->
        changeset

      value when is_binary(value) ->
        normalized = String.trim(value)
        changeset = Ash.Changeset.force_change_attribute(changeset, :api_key_last4, normalized)

        if String.length(normalized) == 4 do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :api_key_last4,
            message: "must be exactly 4 characters"
          )
        end
    end
  end

  defp app_env, do: Application.get_env(:event_sales, :env, :dev)
end
