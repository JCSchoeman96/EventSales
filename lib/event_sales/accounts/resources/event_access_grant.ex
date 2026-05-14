defmodule EventSales.Accounts.Resources.EventAccessGrant do
  @moduledoc """
  UUID-scoped event access grant for future event owners and event staff.

  Slice 2.0 intentionally stores `event_id` as a UUID without a Catalog
  relationship. Slice 3.0 owns the Catalog event table and later FK wiring.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Accounts

  postgres do
    table "accounts_event_access_grants"
    repo EventSales.Repo

    custom_indexes do
      index :user_id
      index :event_id
      index :role
      index :expires_at

      index [:user_id, :event_id, :role],
        unique: true,
        where: "active = TRUE",
        name: "accounts_grants_unique_active_role_idx"
    end
  end

  actions do
    defaults [
      :read,
      create: [:user_id, :event_id, :role, :expires_at, :active],
      update: [:expires_at, :active]
    ]

    update :revoke do
      change set_attribute(:active, false)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      constraints one_of: [:event_owner, :event_staff]
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      public? true
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, EventSales.Accounts.Resources.User do
      allow_nil? false
      public? true
    end
  end
end
