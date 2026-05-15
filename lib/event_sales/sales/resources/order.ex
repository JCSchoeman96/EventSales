defmodule EventSales.Sales.Resources.Order do
  @moduledoc """
  Normalized WooCommerce order header and durable order-level status truth.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Sales,
    extensions: [AshStateMachine]

  alias EventSales.Sales.Changes.GuardSourceVersion
  alias EventSales.Sales.Changes.SyncStatusFromSource

  @order_statuses [
    :pending,
    :processing,
    :on_hold,
    :completed,
    :cancelled,
    :refunded,
    :failed
  ]

  @create_accept [
    :source_system_id,
    :woo_order_id,
    :order_number,
    :status,
    :currency,
    :completed_at,
    :created_at_source,
    :updated_at_source,
    :customer_name,
    :customer_email,
    :raw_total,
    :raw_discount_total,
    :raw_tax_total
  ]

  postgres do
    table "sales_orders"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [:source_system_id, :woo_order_id],
        unique: true,
        name: "sales_orders_unique_source_order_idx"

      index :source_system_id, name: "sales_orders_source_system_id_idx"
      index :status, name: "sales_orders_status_idx"
      index :completed_at, name: "sales_orders_completed_at_idx"
      index :updated_at_source, name: "sales_orders_updated_at_source_idx"
      index :order_number, name: "sales_orders_order_number_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_normalized do
      accept @create_accept
    end

    update :sync_status_from_source do
      accept [:status, :updated_at_source, :completed_at]
      require_atomic? false
      change GuardSourceVersion
      change SyncStatusFromSource
    end

    update :mark_processing do
      change transition_state(:processing)
    end

    update :mark_completed do
      change transition_state(:completed)
    end

    update :mark_cancelled do
      change transition_state(:cancelled)
    end

    update :cancel_pending do
      change transition_state(:cancelled)
    end

    update :mark_refunded do
      change transition_state(:refunded)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :woo_order_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :order_number, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      constraints one_of: @order_statuses
      public? true
    end

    attribute :currency, :string do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
    end

    attribute :created_at_source, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :updated_at_source, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :customer_name, :string do
      public? true
    end

    attribute :customer_email, :string do
      public? true
    end

    attribute :raw_total, :decimal do
      allow_nil? false
      public? true
    end

    attribute :raw_discount_total, :decimal do
      allow_nil? false
      default Decimal.new(0)
      public? true
    end

    attribute :raw_tax_total, :decimal do
      allow_nil? false
      default Decimal.new(0)
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

    has_many :order_items, EventSales.Sales.Resources.OrderItem do
      destination_attribute :order_id
    end

    has_many :coupon_snapshots, EventSales.Sales.Resources.CouponSnapshot do
      destination_attribute :order_id
    end
  end

  identities do
    identity :unique_source_order, [:source_system_id, :woo_order_id]
  end

  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending
    extra_states [:on_hold, :failed]

    transitions do
      transition :mark_processing, from: :pending, to: :processing
      transition :mark_completed, from: :processing, to: :completed
      transition :mark_cancelled, from: :processing, to: :cancelled
      transition :cancel_pending, from: :pending, to: :cancelled
      transition :mark_refunded, from: :completed, to: :refunded
    end
  end
end
