defmodule EventSales.Sales.Resources.RefundLine do
  @moduledoc """
  Durable line-level facts for one WooCommerce Refund.

  `order_item_id` is deliberately nullable. A future persistence service may
  populate it only after proving the exact `_refunded_item_id` binder belongs
  to the same parent Order.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Sales

  @normalized_accept [
    :refund_id,
    :order_item_id,
    :woo_refund_line_item_id,
    :woo_refunded_item_id,
    :woo_product_id,
    :woo_variation_id,
    :refunded_quantity,
    :refund_subtotal_amount,
    :refund_total_amount,
    :refund_total_tax,
    :binding_reason,
    :validation_reason
  ]

  postgres do
    table "sales_refund_lines"
    repo EventSales.Repo

    references do
      reference :refund,
        on_delete: :restrict,
        on_update: :update

      reference :order_item,
        on_delete: :nilify,
        on_update: :update
    end

    custom_indexes do
      index :order_item_id, name: "sales_refund_lines_order_item_id_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_normalized do
      accept @normalized_accept
    end

    update :sync_normalized do
      accept [
        :order_item_id,
        :woo_refunded_item_id,
        :woo_product_id,
        :woo_variation_id,
        :refunded_quantity,
        :refund_subtotal_amount,
        :refund_total_amount,
        :refund_total_tax,
        :binding_reason,
        :validation_reason
      ]

      require_atomic? false
    end

    update :mark_order_item_not_found do
      public? false
      accept []
      require_atomic? false
      validate &__MODULE__.validate_order_item_binding/2
      change set_attribute(:order_item_id, nil)
      change set_attribute(:binding_reason, "order_item_not_found")
      change set_attribute(:validation_reason, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :woo_refund_line_item_id, :integer do
      allow_nil? false
      constraints min: 1
      public? true
    end

    attribute :woo_refunded_item_id, :integer do
      constraints min: 1
      public? true
    end

    attribute :woo_product_id, :integer do
      constraints min: 1
      public? true
    end

    attribute :woo_variation_id, :integer do
      constraints min: 1
      public? true
    end

    attribute :refunded_quantity, :integer do
      constraints min: 0
      public? true
    end

    attribute :refund_subtotal_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :refund_total_amount, :decimal do
      constraints min: 0
      public? true
    end

    attribute :refund_total_tax, :decimal do
      constraints min: 0
      public? true
    end

    attribute :binding_reason, :string do
      public? true
    end

    attribute :validation_reason, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :refund, EventSales.Sales.Resources.Refund do
      allow_nil? false
      public? true
    end

    belongs_to :order_item, EventSales.Sales.Resources.OrderItem do
      public? true
    end
  end

  identities do
    identity :unique_refund_line, [:refund_id, :woo_refund_line_item_id]
  end

  def validate_order_item_binding(changeset, _context) do
    order_item_id = Ash.Changeset.get_data(changeset, :order_item_id)
    binding_reason = Ash.Changeset.get_data(changeset, :binding_reason)

    if is_binary(order_item_id) and is_nil(binding_reason) do
      :ok
    else
      {:error, message: "only an exactly bound RefundLine can be marked order_item_not_found"}
    end
  end
end
