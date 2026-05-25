defmodule EventSales.Accounts.Resources.User do
  @moduledoc """
  Authenticated EventSales actor for internal admin and event-scoped access.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Accounts,
    extensions: [AshAuthentication]

  postgres do
    table "accounts_users"
    repo EventSales.Repo
  end

  actions do
    defaults [:read, update: [:name, :active]]

    update :set_password do
      accept []

      argument :password, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password_confirmation, :string do
        allow_nil? false
        sensitive? true
      end

      validate confirm(:password, :password_confirmation)
      change set_context(%{strategy_name: :password})
      change AshAuthentication.Strategy.Password.HashPasswordChange
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :user_roles, EventSales.Accounts.Resources.UserRole do
      destination_attribute :user_id
    end

    has_many :event_access_grants, EventSales.Accounts.Resources.EventAccessGrant do
      destination_attribute :user_id
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  authentication do
    strategies do
      password :password do
        identity_field :email
        hashed_password_field :hashed_password
        register_action_accept [:name]
        sign_in_tokens_enabled? false
      end
    end
  end
end
