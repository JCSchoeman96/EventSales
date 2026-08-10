defmodule EventSales.Catalog.Resources.Event do
  @moduledoc """
  Event-level reporting and permission scope for catalog mappings.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Catalog,
    extensions: [AshStateMachine]

  alias EventSales.Catalog.Changes.ValidateEventDates

  postgres do
    table "catalog_events"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :source_system_id,
        :name,
        :slug,
        :starts_at,
        :ends_at,
        :venue_name,
        :booking_fee_type,
        :booking_fee_value,
        :capacity,
        :status,
        :external_event_id,
        :external_event_kind,
        :source_status,
        :source_updated_at,
        :last_synced_at
      ]

      change ValidateEventDates
    end

    update :update do
      accept [
        :name,
        :slug,
        :starts_at,
        :ends_at,
        :venue_name,
        :booking_fee_type,
        :booking_fee_value,
        :capacity,
        :status,
        :external_event_id,
        :external_event_kind,
        :source_status,
        :source_updated_at,
        :last_synced_at
      ]

      require_atomic? false
      change ValidateEventDates
    end

    update :archive do
      accept []
      require_atomic? false
      change set_attribute(:status, :archived)
    end

    update :mark_backfill_pending do
      accept []
      change transition_state(:backfill_pending)
    end

    update :invalidate_onboarding do
      accept []
      change transition_state(:unverified)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :starts_at, :utc_datetime_usec do
      public? true
    end

    attribute :ends_at, :utc_datetime_usec do
      public? true
    end

    attribute :venue_name, :string do
      public? true
    end

    attribute :booking_fee_type, :atom do
      constraints one_of: [:fixed, :percentage]
      public? true
    end

    attribute :booking_fee_value, :decimal do
      public? true
    end

    attribute :capacity, :integer do
      public? true
      constraints min: 0
    end

    attribute :status, :atom do
      allow_nil? false
      default :draft
      constraints one_of: [:draft, :active, :archived, :cancelled]
      public? true
    end

    attribute :analytics_onboarding_state, :atom do
      allow_nil? false
      default :unverified
      constraints one_of: [:unverified, :backfill_pending]
      public? true
    end

    attribute :external_event_id, :integer do
      public? true
    end

    attribute :external_event_kind, :atom do
      constraints one_of: [:tickera_event]
      public? true
    end

    attribute :source_status, :string do
      public? true
    end

    attribute :source_updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_synced_at, :utc_datetime_usec do
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

    has_many :ticket_types, EventSales.Catalog.Resources.TicketType do
      destination_attribute :event_id
    end

    has_many :product_mappings, EventSales.Catalog.Resources.ProductMapping do
      destination_attribute :event_id
    end

    has_one :dashboard_setting, EventSales.Catalog.Resources.EventDashboardSetting do
      destination_attribute :event_id
    end
  end

  identities do
    identity :unique_slug_per_source, [:source_system_id, :slug]
  end

  state_machine do
    state_attribute :analytics_onboarding_state
    initial_states [:unverified]
    default_initial_state :unverified

    transitions do
      transition :mark_backfill_pending, from: :unverified, to: :backfill_pending
      transition :invalidate_onboarding, from: :backfill_pending, to: :unverified
    end
  end

  validations do
    validate present([:name, :slug, :source_system_id]) do
      on [:create]
    end
  end
end
