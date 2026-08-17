defmodule EventSales.Repo.Migrations.M305aRefundFacts do
  use Ecto.Migration

  def up do
    create table(:sales_refunds, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :woo_order_id, :bigint, null: false
      add :woo_refund_id, :bigint, null: false
      add :currency, :text
      add :source_state, :text, null: false, default: "active"
      add :detail_status, :text, null: false, default: "reference_only"
      add :unresolved_reason, :text
      add :summary_total_amount, :decimal
      add :header_amount, :decimal
      add :shipping_refund_amount, :decimal
      add :shipping_refund_tax, :decimal
      add :fee_refund_amount, :decimal
      add :fee_refund_tax, :decimal
      add :unallocated_header_amount, :decimal
      add :reason, :text
      add :source_created_at, :utc_datetime_usec
      add :voided_at, :utc_datetime_usec
      add :void_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :source_system_id,
          references(:catalog_source_systems,
            column: :id,
            name: "sales_refunds_source_system_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict,
            on_update: :update_all
          ),
          null: false

      add :order_id,
          references(:sales_orders,
            column: :id,
            name: "sales_refunds_order_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all,
            on_update: :update_all
          )
    end

    create unique_index(:sales_refunds, [:source_system_id, :woo_order_id, :woo_refund_id],
             name: "sales_refunds_unique_source_order_refund_index"
           )

    create index(:sales_refunds, [:order_id], name: "sales_refunds_order_id_idx")

    create constraint(:sales_refunds, :sales_refunds_positive_source_identity,
             check: "woo_order_id > 0 AND woo_refund_id > 0"
           )

    create constraint(:sales_refunds, :sales_refunds_valid_state,
             check: "source_state IN ('active', 'voided')"
           )

    create constraint(:sales_refunds, :sales_refunds_valid_detail_status,
             check: "detail_status IN ('reference_only', 'complete', 'unresolved')"
           )

    create constraint(:sales_refunds, :sales_refunds_non_negative_amounts,
             check: """
             (summary_total_amount IS NULL OR summary_total_amount >= 0) AND
             (header_amount IS NULL OR header_amount >= 0) AND
             (shipping_refund_amount IS NULL OR shipping_refund_amount >= 0) AND
             (shipping_refund_tax IS NULL OR shipping_refund_tax >= 0) AND
             (fee_refund_amount IS NULL OR fee_refund_amount >= 0) AND
             (fee_refund_tax IS NULL OR fee_refund_tax >= 0) AND
             (unallocated_header_amount IS NULL OR unallocated_header_amount >= 0)
             """
           )

    create table(:sales_refund_lines, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :woo_refund_line_item_id, :bigint, null: false
      add :woo_refunded_item_id, :bigint
      add :woo_product_id, :bigint
      add :woo_variation_id, :bigint
      add :refunded_quantity, :bigint
      add :refund_subtotal_amount, :decimal
      add :refund_total_amount, :decimal
      add :refund_total_tax, :decimal
      add :binding_reason, :text
      add :validation_reason, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :refund_id,
          references(:sales_refunds,
            column: :id,
            name: "sales_refund_lines_refund_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict,
            on_update: :update_all
          ),
          null: false

      add :order_item_id,
          references(:sales_order_items,
            column: :id,
            name: "sales_refund_lines_order_item_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all,
            on_update: :update_all
          )
    end

    create unique_index(:sales_refund_lines, [:refund_id, :woo_refund_line_item_id],
             name: "sales_refund_lines_unique_refund_line_index"
           )

    create index(:sales_refund_lines, [:order_item_id],
             name: "sales_refund_lines_order_item_id_idx"
           )

    create constraint(:sales_refund_lines, :sales_refund_lines_positive_source_identity,
             check: "woo_refund_line_item_id > 0"
           )

    create constraint(:sales_refund_lines, :sales_refund_lines_positive_optional_identity,
             check: """
             (woo_refunded_item_id IS NULL OR woo_refunded_item_id > 0) AND
             (woo_product_id IS NULL OR woo_product_id > 0) AND
             (woo_variation_id IS NULL OR woo_variation_id > 0)
             """
           )

    create constraint(:sales_refund_lines, :sales_refund_lines_non_negative_primitives,
             check: """
             (refunded_quantity IS NULL OR refunded_quantity >= 0) AND
             (refund_subtotal_amount IS NULL OR refund_subtotal_amount >= 0) AND
             (refund_total_amount IS NULL OR refund_total_amount >= 0) AND
             (refund_total_tax IS NULL OR refund_total_tax >= 0)
             """
           )
  end

  def down do
    drop constraint(:sales_refund_lines, "sales_refund_lines_non_negative_primitives")

    drop constraint(:sales_refund_lines, "sales_refund_lines_positive_optional_identity")

    drop constraint(:sales_refund_lines, "sales_refund_lines_positive_source_identity")

    drop_if_exists index(:sales_refund_lines, [:order_item_id],
                     name: "sales_refund_lines_order_item_id_idx"
                   )

    drop_if_exists unique_index(:sales_refund_lines, [:refund_id, :woo_refund_line_item_id],
                     name: "sales_refund_lines_unique_refund_line_index"
                   )

    drop constraint(:sales_refund_lines, "sales_refund_lines_order_item_id_fkey")
    drop constraint(:sales_refund_lines, "sales_refund_lines_refund_id_fkey")
    drop table(:sales_refund_lines)

    drop constraint(:sales_refunds, "sales_refunds_non_negative_amounts")
    drop constraint(:sales_refunds, "sales_refunds_valid_detail_status")
    drop constraint(:sales_refunds, "sales_refunds_valid_state")
    drop constraint(:sales_refunds, "sales_refunds_positive_source_identity")

    drop_if_exists index(:sales_refunds, [:order_id], name: "sales_refunds_order_id_idx")

    drop_if_exists unique_index(
                     :sales_refunds,
                     [:source_system_id, :woo_order_id, :woo_refund_id],
                     name: "sales_refunds_unique_source_order_refund_index"
                   )

    drop constraint(:sales_refunds, "sales_refunds_order_id_fkey")
    drop constraint(:sales_refunds, "sales_refunds_source_system_id_fkey")
    drop table(:sales_refunds)
  end
end
