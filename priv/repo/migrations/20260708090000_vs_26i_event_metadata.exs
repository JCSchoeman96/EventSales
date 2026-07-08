defmodule EventSales.Repo.Migrations.Vs26iEventMetadata do
  use Ecto.Migration

  def up do
    alter table(:catalog_events) do
      add :venue_name, :text
      add :booking_fee_type, :text
      add :booking_fee_value, :decimal
    end
  end

  def down do
    alter table(:catalog_events) do
      remove :booking_fee_value
      remove :booking_fee_type
      remove :venue_name
    end
  end
end
