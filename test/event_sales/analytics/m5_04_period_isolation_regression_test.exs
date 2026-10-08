# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodIsolationRegressionTest do
  @moduledoc false

  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
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
      source = Cert.create_unboxed_certification_source!()
      event = Cert.prepare_analytics_ready_event!(source)

      ticket = SalesHelpers.create_ticket_type!(event, %{name: "Isolation probe"})
      Cert.ingest_sale_and_refresh!(event, nil, source, ticket, @sale_at, @now)

      Cert.cleanup_unboxed_certification_source!(source.id)
    end)

    assert Ash.count!(Order, domain: Sales) == before_orders
    assert Ash.count!(OrderItem, domain: Sales) == before_items
  end

  test "source-scoped unboxed cleanup removes a source with no events" do
    before_sources = Ash.count!(SourceSystem, domain: Catalog)
    before_events = Ash.count!(Event, domain: Catalog)

    UnboxedPostgres.with_exclusive_setup(fn ->
      source = Cert.create_unboxed_certification_source!()
      Cert.cleanup_unboxed_certification_source!(source.id)
      Cert.cleanup_unboxed_certification_source!(source.id)
    end)

    assert Ash.count!(SourceSystem, domain: Catalog) == before_sources
    assert Ash.count!(Event, domain: Catalog) == before_events
  end

  test "source-scoped unboxed cleanup removes a partially prepared event fixture" do
    before_sources = Ash.count!(SourceSystem, domain: Catalog)
    before_events = Ash.count!(Event, domain: Catalog)

    UnboxedPostgres.with_exclusive_setup(fn ->
      source = Cert.create_unboxed_certification_source!()
      _event = SalesHelpers.create_event!(source, %{name: "Partial prep probe"})
      Cert.cleanup_unboxed_certification_source!(source.id)
    end)

    assert Ash.count!(SourceSystem, domain: Catalog) == before_sources
    assert Ash.count!(Event, domain: Catalog) == before_events
  end

  test "complete unboxed fixture cleanup via source id is idempotent" do
    before_orders = Ash.count!(Order, domain: Sales)

    UnboxedPostgres.with_exclusive_setup(fn ->
      source = Cert.create_unboxed_certification_source!()
      event = Cert.prepare_analytics_ready_event!(source)
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "Idempotent probe"})
      Cert.ingest_sale_and_refresh!(event, nil, source, ticket, @sale_at, @now)

      Cert.cleanup_unboxed_certification_source!(source.id)
      Cert.cleanup_unboxed_certification_source!(source.id)
    end)

    assert Ash.count!(Order, domain: Sales) == before_orders
  end
end
