defmodule EventSales.Sales.Resources.CouponSnapshot do
  @moduledoc """
  Coupon/discount snapshot attached to a normalized order header.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Sales

  postgres do
    table "sales_coupon_snapshots"
    repo EventSales.Repo

    references do
      reference :order, on_delete: :delete, on_update: :update
    end

    custom_indexes do
      index :order_id, name: "sales_coupon_snapshots_order_id_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_snapshot do
      accept [:order_id, :code, :discount_amount, :discount_tax]
    end

    update :sync_from_order do
      accept [:discount_amount, :discount_tax]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :code, :string do
      allow_nil? false
      public? true
    end

    attribute :discount_amount, :decimal do
      allow_nil? false
      public? true
    end

    attribute :discount_tax, :decimal do
      allow_nil? false
      default Decimal.new(0)
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :order, EventSales.Sales.Resources.Order do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_order_code, [:order_id, :code]
  end
end
