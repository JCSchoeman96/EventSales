# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodIsolationRegressionTest do
  @moduledoc false

  use EventSales.DataCase, async: false

  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.M5_04PeriodCertificationHelpers, as: Cert
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.UnboxedPostgres

  @now ~U[2026-05-17 10:17:33.000000Z]
  @sale_at ~U[2026-05-16 08:00:00.000000Z]

  test "unboxed G2 sale fixture cleanup does not leak orders to the next sandboxed test" do
    before_orders = Ash.count!(Order, domain: Sales)
    before_items = Ash.count!(OrderItem, domain: Sales)

    UnboxedPostgres.with_exclusive_setup(fn ->
      source = SalesHelpers.create_source_system!()
      event = Cert.prepare_analytics_ready_event!(source)

      on_exit(fn ->
        Cert.cleanup_unboxed_certification_fixture!(event.id, source.id)
      end)

      ticket = SalesHelpers.create_ticket_type!(event, %{name: "Isolation probe"})
      Cert.ingest_sale_and_refresh!(event, nil, source, ticket, @sale_at, @now)

      Cert.cleanup_unboxed_certification_fixture!(event.id, source.id)
    end)

    assert Ash.count!(Order, domain: Sales) == before_orders
    assert Ash.count!(OrderItem, domain: Sales) == before_items
  end
end
