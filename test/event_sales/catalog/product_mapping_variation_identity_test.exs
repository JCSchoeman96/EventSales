defmodule EventSales.Catalog.ProductMappingVariationIdentityTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.Resources.TicketType
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.Repo

  test "A matching variation identity create succeeds" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Variation Match",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })

    assert mapping.woo_product_id == 500
    assert mapping.woo_variation_id == 501
    assert mapping.ticket_type_id == ticket.id
  end

  test "B nil external_variation_id mirror with matching canonical kind/id succeeds" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Legacy Variation",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: nil
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })

    assert mapping.woo_variation_id == 501
    assert ticket.external_variation_id == nil
  end

  test "C wrong external_ticket_type_id is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Wrong Variation Id",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 502,
        external_product_id: 500,
        external_variation_id: 502
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })
    end

    assert mapping_row_count() == before_count
    refute_enqueued(worker: MappingChangedWorker)
  end

  test "D explicit external_variation_id mismatch is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Mirror Mismatch",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 999
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })
    end

    assert mapping_row_count() == before_count
  end

  test "E variation mapping bound to woo_product TicketType is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Product Kind",
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 500,
        external_product_id: 500
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })
    end

    assert mapping_row_count() == before_count
  end

  test "F variation mapping with missing TicketType variation identity is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Incomplete Variation",
        external_ticket_type_kind: nil,
        external_ticket_type_id: nil,
        external_product_id: 500
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })
    end

    assert mapping_row_count() == before_count
  end

  test "G product-level mapping bound to woo_variation TicketType is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Variation Ticket",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })
    end

    assert mapping_row_count() == before_count
  end

  test "H product-level mapping with product TicketType is allowed" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Product Ticket",
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 500,
        external_product_id: 500
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })

    assert mapping.woo_product_id == 500
    assert mapping.woo_variation_id == nil
  end

  test "I update variation id into mismatch is rejected and original unchanged" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Stable Variation",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501,
        current_label: "Original"
      })

    drain_side_effect_messages()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(mapping, %{woo_variation_id: 502}, action: :update, domain: Catalog)
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.woo_variation_id == 501
    assert reloaded.current_label == "Original"
  end

  test "J remap to wrong variation TicketType is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket_match =
      create_ticket_type!(event, %{
        name: "Match Variation",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    ticket_mismatch =
      create_ticket_type!(event, %{
        name: "Mismatch Variation",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 502,
        external_product_id: 500,
        external_variation_id: 502
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket_match}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(
        mapping,
        %{ticket_type_id: ticket_mismatch.id},
        action: :remap,
        domain: Catalog
      )
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.ticket_type_id == ticket_match.id
    assert reloaded.woo_variation_id == 501
  end

  test "K matching variation remap is allowed" do
    source = create_source_system!()
    event = create_event!(source)

    ticket_a =
      create_ticket_type!(event, %{
        name: "Variation A",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    ticket_b =
      create_ticket_type!(event, %{
        name: "Variation B",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 502,
        external_product_id: 500,
        external_variation_id: 502
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket_a}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })

    remapped =
      Ash.update!(
        mapping,
        %{ticket_type_id: ticket_b.id, woo_variation_id: 502},
        action: :remap,
        domain: Catalog
      )

    assert remapped.ticket_type_id == ticket_b.id
    assert remapped.woo_variation_id == 502
  end

  test "L product to variation incoherent transition is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Product Ticket",
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 500,
        external_product_id: 500
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })

    drain_side_effect_messages()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(mapping, %{woo_variation_id: 501}, action: :update, domain: Catalog)
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.woo_variation_id == nil
  end

  test "M variation to product incoherent transition is rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Variation Ticket",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })

    drain_side_effect_messages()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(mapping, %{woo_variation_id: nil}, action: :update, domain: Catalog)
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.woo_variation_id == 501
  end

  test "N TicketType Event mismatch remains rejected" do
    source = create_source_system!()
    event_a = create_event!(source, %{name: "Event A", slug: "var-event-a"})
    event_b = create_event!(source, %{name: "Event B", slug: "var-event-b"})

    ticket_on_a =
      create_ticket_type!(event_a, %{
        name: "On A",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event_b.id,
          ticket_type_id: ticket_on_a.id,
          woo_product_id: 500,
          woo_variation_id: 501,
          original_label: "Bad Event",
          current_label: "Bad Event"
        },
        action: :create,
        domain: Catalog
      )
    end

    assert mapping_row_count() == before_count
  end

  test "O parent product mismatch remains rejected" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Parent Mismatch",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 600,
        external_variation_id: 501
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: 501
      })
    end

    assert mapping_row_count() == before_count
  end

  test "P source/Event mismatch remains rejected" do
    source_a = create_source_system!()
    source_b = create_source_system!()
    event_b = create_event!(source_b, %{name: "Event B", slug: "var-cross-source"})

    ticket_b =
      create_ticket_type!(event_b, %{
        name: "Cross Source",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 500,
        external_variation_id: 501
      })

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source_a.id,
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          woo_product_id: 500,
          woo_variation_id: 501,
          original_label: "Cross",
          current_label: "Cross"
        },
        action: :create,
        domain: Catalog
      )
    end

    assert mapping_row_count() == before_count
    refute_enqueued(worker: MappingChangedWorker)
  end

  defp create_source_system!(attrs \\ %{}) do
    defaults = %{
      name: "Woo Store",
      kind: :woocommerce,
      base_url: "https://store-#{System.unique_integer([:positive])}.example.test"
    }

    Ash.create!(SourceSystem, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_event!(source, attrs \\ %{}) do
    defaults = %{
      source_system_id: source.id,
      name: "Event",
      slug: "event-#{System.unique_integer([:positive])}",
      status: :active
    }

    Ash.create!(Event, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_ticket_type!(event, attrs) do
    defaults = %{event_id: event.id, name: "Ticket", active: true}
    Ash.create!(TicketType, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_mapping!(%{source: source, event: event, ticket: ticket}, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Label",
      current_label: "Label",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp mapping_row_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM catalog_product_mappings")
    count
  end

  defp mapping_worker do
    Oban.Worker.to_string(MappingChangedWorker)
  end

  defp drain_side_effect_messages do
    from(j in Oban.Job, where: j.worker == ^mapping_worker())
    |> Repo.delete_all()
  end
end
