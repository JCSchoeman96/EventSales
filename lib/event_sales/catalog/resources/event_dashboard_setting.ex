defmodule EventSales.Catalog.Resources.EventDashboardSetting do
  @moduledoc """
  Per-event dashboard visibility configuration for revenue, orders, and PII.

  `access_expires_at` is enforced by `EventSales.Accounts.Policies` when consulting
  revenue visibility flags. When set and in the past, dashboard-derived access is denied.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Catalog

  postgres do
    table "catalog_event_dashboard_settings"
    repo EventSales.Repo

    references do
      reference :event, on_delete: :delete, on_update: :update
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :event_id,
        :revenue_visible_to_event_owner,
        :revenue_visible_to_event_staff,
        :order_numbers_visible,
        :pii_visible,
        :access_expires_at
      ]
    end

    update :update do
      accept [
        :revenue_visible_to_event_owner,
        :revenue_visible_to_event_staff,
        :order_numbers_visible,
        :pii_visible,
        :access_expires_at
      ]

      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :revenue_visible_to_event_owner, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :revenue_visible_to_event_staff, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :order_numbers_visible, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :pii_visible, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :access_expires_at, :utc_datetime_usec do
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
  end

  identities do
    identity :unique_event, [:event_id]
  end

  validations do
    validate present(:event_id) do
      on [:create]
    end
  end
end
