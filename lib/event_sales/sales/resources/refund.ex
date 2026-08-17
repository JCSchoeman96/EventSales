defmodule EventSales.Sales.Resources.Refund do
  @moduledoc """
  Durable source-scoped WooCommerce refund facts.

  Refunds are independent financial adjustments. They never replace the
  original Order or OrderItem sale facts.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Sales

  @source_states [:active, :voided]
  @detail_statuses [:reference_only, :complete, :unresolved]

  @reference_accept [
    :source_system_id,
    :order_id,
    :woo_order_id,
    :woo_refund_id,
    :currency,
    :summary_total_amount,
    :reason,
    :unresolved_reason
  ]

  @normalized_accept [
    :source_system_id,
    :order_id,
    :woo_order_id,
    :woo_refund_id,
    :currency,
    :source_state,
    :detail_status,
    :unresolved_reason,
    :summary_total_amount,
    :header_amount,
    :shipping_refund_amount,
    :shipping_refund_tax,
    :fee_refund_amount,
    :fee_refund_tax,
    :unallocated_header_amount,
    :reason,
    :source_created_at,
    :voided_at,
    :void_reason
  ]

  postgres do
    table "sales_refunds"
    repo EventSales.Repo

    references do
      reference :source_system,
        on_delete: :restrict,
        on_update: :update

      reference :order,
        on_delete: :nilify,
        on_update: :update
    end

    custom_indexes do
      index :order_id, name: "sales_refunds_order_id_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_reference do
      accept @reference_accept
    end

    create :create_normalized do
      accept @normalized_accept
    end

    update :sync_normalized do
      accept [
        :order_id,
        :currency,
        :detail_status,
        :unresolved_reason,
        :summary_total_amount,
        :header_amount,
        :shipping_refund_amount,
        :shipping_refund_tax,
        :fee_refund_amount,
        :fee_refund_tax,
        :unallocated_header_amount,
        :reason,
        :source_created_at,
        :voided_at,
        :void_reason
      ]

      require_atomic? false
    end

    update :mark_unresolved do
      accept [:unresolved_reason]
      require_atomic? false
      change set_attribute(:detail_status, :unresolved)
    end

    update :mark_voided do
      accept [:void_reason, :voided_at]
      require_atomic? false
      change set_attribute(:source_state, :voided)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :woo_order_id, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :woo_refund_id, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :currency, :string do
      public? true
    end

    attribute :source_state, :atom do
      allow_nil? false
      default :active
      constraints one_of: @source_states
      public? true
    end

    attribute :detail_status, :atom do
      allow_nil? false
      default :reference_only
      constraints one_of: @detail_statuses
      public? true
    end

    attribute :unresolved_reason, :string do
      public? true
    end

    attribute :summary_total_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :header_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :shipping_refund_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :shipping_refund_tax, :decimal do
      constraints min: 0
      public? true
    end

    attribute :fee_refund_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :fee_refund_tax, :decimal do
      constraints min: 0
      public? true
    end

    attribute :unallocated_header_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :reason, :string do
      public? true
    end

    attribute :source_created_at, :utc_datetime_usec do
      public? true
    end

    attribute :voided_at, :utc_datetime_usec do
      public? true
    end

    attribute :void_reason, :string do
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

    belongs_to :order, EventSales.Sales.Resources.Order do
      public? true
    end

    has_many :refund_lines, EventSales.Sales.Resources.RefundLine do
      destination_attribute :refund_id
    end
  end

  identities do
    identity :unique_source_order_refund, [:source_system_id, :woo_order_id, :woo_refund_id]
  end
end
