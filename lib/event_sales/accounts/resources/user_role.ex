defmodule EventSales.Accounts.Resources.UserRole do
  @moduledoc """
  Join resource assigning global roles to users.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Accounts

  postgres do
    table "accounts_user_roles"
    repo EventSales.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:user_id, :role_id]]
  end

  attributes do
    uuid_primary_key :id

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, EventSales.Accounts.Resources.User do
      allow_nil? false
      public? true
    end

    belongs_to :role, EventSales.Accounts.Resources.Role do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_user_role, [:user_id, :role_id]
  end
end
