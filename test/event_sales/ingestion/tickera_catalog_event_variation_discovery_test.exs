defmodule EventSales.Ingestion.TickeraCatalogEventVariationDiscoveryTest do
  @moduledoc """
  Path 1 M2-05 certification: exact local Event → authoritative Woo variation membership.

  Source variation identity is locked as
  `(source_system_id, woo_product_id, woo_variation_id)`.
  """

  use EventSales.DataCase, async: false

  alias EventSales.Catalog.TickeraCatalog.CatalogRow
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "projects exact variation identities for the selected Event", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Variation Membership Event",
        slug: "variation-membership-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 502}
    ]

    assert {:ok, %{variations: variations, variation_count: 2}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)

    assert variations == [
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 501
             },
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 502
             }
           ]
  end

  test "each variation identity includes the locked source/product/variation tuple", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Tuple Event",
        slug: "tuple-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501}
    ]

    assert {:ok, %{variations: [variation]}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)

    assert Map.keys(variation) |> Enum.sort() ==
             [:source_system_id, :woo_product_id, :woo_variation_id]

    assert variation.source_system_id == source.id
    assert variation.woo_product_id == 500
    assert variation.woo_variation_id == 501
  end

  test "source evidence cannot be relabelled under another SourceSystem" do
    source_a =
      SalesHelpers.create_source_system!(%{base_url: "https://m2-05-relabel-a.example.test"})

    source_b =
      SalesHelpers.create_source_system!(%{base_url: "https://m2-05-relabel-b.example.test"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Source A Event 123",
        slug: "relabel-source-a-123",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501}
    ]

    assert {:ok, %{variations: variations}} =
             TickeraCatalogSync.project_event_variations(event_a.id, rows)

    assert variations == [
             %{
               source_system_id: source_a.id,
               woo_product_id: 500,
               woo_variation_id: 501
             }
           ]

    refute Enum.any?(variations, &(&1.source_system_id == source_b.id))
    refute function_exported?(TickeraCatalogSync, :project_event_variations, 3)
  end

  test "foreign Event row fails closed", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Foreign Row Event",
        slug: "foreign-row-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501},
      %CatalogRow{tickera_event_id: 999, woo_product_id: 700, woo_variation_id: 701}
    ]

    assert {:error, :foreign_event_row} =
             TickeraCatalogSync.project_event_variations(event.id, rows)
  end

  test "duplicate exact variation rows converge to one identity", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Duplicate Variation Event",
        slug: "duplicate-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501}
    ]

    assert {:ok, %{variations: variations, variation_count: 1}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)

    assert variations == [
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 501
             }
           ]
  end

  test "same variation id under different parents remains distinct", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Parent Sensitive Event",
        slug: "parent-sensitive-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 900},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 600, woo_variation_id: 900}
    ]

    assert {:ok, %{variations: variations, variation_count: 2}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)

    assert variations == [
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 900
             },
             %{
               source_system_id: source.id,
               woo_product_id: 600,
               woo_variation_id: 900
             }
           ]
  end

  test "simple product rows contribute no variation identity", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Simple Product Event",
        slug: "simple-product-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{
        tickera_event_id: 123,
        woo_product_id: 600,
        woo_variation_id: nil,
        ticket_type_kind: :woo_product
      }
    ]

    assert {:ok, %{variations: [], variation_count: 0}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)
  end

  test "mixed simple and variation parents project only variation identities", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Mixed Parents Event",
        slug: "mixed-parents-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 502},
      %CatalogRow{
        tickera_event_id: 123,
        woo_product_id: 600,
        woo_variation_id: nil,
        ticket_type_kind: :woo_product
      }
    ]

    assert {:ok, %{variations: variations, variation_count: 2}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)

    assert variations == [
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 501
             },
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 502
             }
           ]
  end

  test "zero variation rows remain explicit without fabrication", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Zero Variation Event",
        slug: "zero-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    assert {:ok, %{variations: [], variation_count: 0}} =
             TickeraCatalogSync.project_event_variations(event.id, [])
  end

  test "invalid variation id fails closed", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Invalid Variation Event",
        slug: "invalid-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 0}
    ]

    assert {:error, :invalid_variation_identity} =
             TickeraCatalogSync.project_event_variations(event.id, rows)
  end

  test "invalid parent product id on variation-bearing row fails closed", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Invalid Parent Variation Event",
        slug: "invalid-parent-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: nil, woo_variation_id: 501}
    ]

    assert {:error, :invalid_product_identity} =
             TickeraCatalogSync.project_event_variations(event.id, rows)
  end

  test "variation identities sort deterministically by product then variation", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Sort Event",
        slug: "sort-variation-event",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 600, woo_variation_id: 602},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 502},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 600, woo_variation_id: 601}
    ]

    assert {:ok, %{variations: variations, variation_count: 4}} =
             TickeraCatalogSync.project_event_variations(event.id, rows)

    assert variations == [
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 501
             },
             %{
               source_system_id: source.id,
               woo_product_id: 500,
               woo_variation_id: 502
             },
             %{
               source_system_id: source.id,
               woo_product_id: 600,
               woo_variation_id: 601
             },
             %{
               source_system_id: source.id,
               woo_product_id: 600,
               woo_variation_id: 602
             }
           ]
  end

  test "projection fails closed when local Event is absent" do
    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501}
    ]

    assert {:error, :event_not_found} =
             TickeraCatalogSync.project_event_variations(Ecto.UUID.generate(), rows)
  end

  test "same numeric IDs remain source-isolated through selected local Events" do
    source_a =
      SalesHelpers.create_source_system!(%{base_url: "https://m2-05-iso-a.example.test"})

    source_b =
      SalesHelpers.create_source_system!(%{base_url: "https://m2-05-iso-b.example.test"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Source A Event 123",
        slug: "iso-source-a-123",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Source B Event 123",
        slug: "iso-source-b-123",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501}
    ]

    assert {:ok, %{variations: [variation_a]}} =
             TickeraCatalogSync.project_event_variations(event_a.id, rows)

    assert {:ok, %{variations: [variation_b]}} =
             TickeraCatalogSync.project_event_variations(event_b.id, rows)

    assert variation_a == %{
             source_system_id: source_a.id,
             woo_product_id: 500,
             woo_variation_id: 501
           }

    assert variation_b == %{
             source_system_id: source_b.id,
             woo_product_id: 500,
             woo_variation_id: 501
           }

    refute variation_a.source_system_id == variation_b.source_system_id
  end
end
