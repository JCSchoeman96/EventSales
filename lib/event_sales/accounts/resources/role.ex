defmodule EventSales.Accounts.Resources.Role do
  @moduledoc """
  Canonical global role catalog.

  Event-scoped roles are represented by `EventAccessGrant`, not this resource.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Accounts

  postgres do
    table "accounts_roles"
    repo EventSales.Repo
  end

  actions do
    defaults [:read, create: [:name, :description], update: [:description]]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :atom do
      allow_nil? false
      constraints one_of: [:admin, :staff]
      public? true
    end

    attribute :description, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :user_roles, EventSales.Accounts.Resources.UserRole do
      destination_attribute :role_id
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
