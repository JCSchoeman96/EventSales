defmodule EventSales.Repo.Migrations.Vs26jEventFirstOrderAttribution do
  use Ecto.Migration

  def change do
    alter table(:sales_order_items) do
      add :source_tickera_event_id, :bigint
      add :attribution_status_reason, :text
    end

    create index(
             :sales_order_items,
             [
               :source_tickera_event_id,
               :woo_product_id,
               :woo_variation_id
             ],
             name: "sales_order_items_source_event_product_variation_idx"
           )

    create index(:sales_order_items, [:attribution_status_reason],
             name: "sales_order_items_attribution_status_reason_idx"
           )

    create index(:sales_order_items, [:mapping_status, :attribution_status_reason],
             name: "sales_order_items_mapping_status_attribution_reason_idx"
           )
  end
end
