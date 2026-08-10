defmodule EventSales.Catalog.ProductMappingParentIdentityTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.Resources.TicketType
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.Repo

  test "matching product TicketType parent create succeeds" do
    source = create_source_system!()
    event = create_event!(source)
    ticket = create_ticket_type!(event, %{external_product_id: 500})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })

    assert mapping.woo_product_id == 500
    assert mapping.ticket_type_id == ticket.id
  end

  test "nil TicketType parent create succeeds" do
    source = create_source_system!()
    event = create_event!(source)
    ticket = create_ticket_type!(event, %{external_product_id: nil})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })

    assert mapping.woo_product_id == 500
    assert ticket.external_product_id == nil
  end

  test "explicit parent mismatch create is rejected and no row is persisted" do
    source = create_source_system!()
    event = create_event!(source)
    ticket = create_ticket_type!(event, %{external_product_id: 600})

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })
    end

    assert mapping_row_count() == before_count
    refute_enqueued(worker: MappingChangedWorker)
  end

  test "TicketType Event mismatch remains rejected" do
    source = create_source_system!()
    event_a = create_event!(source, %{name: "Event A", slug: "parent-event-a"})
    event_b = create_event!(source, %{name: "Event B", slug: "parent-event-b"})
    ticket_on_a = create_ticket_type!(event_a, %{external_product_id: 500})

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event_b.id,
          ticket_type_id: ticket_on_a.id,
          woo_product_id: 500,
          woo_variation_id: nil,
          original_label: "Bad Event",
          current_label: "Bad Event"
        },
        action: :create,
        domain: Catalog
      )
    end

    assert mapping_row_count() == before_count
  end

  test "update introducing parent mismatch is rejected and original row remains unchanged" do
    source = create_source_system!()
    event = create_event!(source)
    ticket = create_ticket_type!(event, %{external_product_id: 500})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil,
        current_label: "Original"
      })

    drain_side_effect_messages()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(mapping, %{woo_product_id: 600}, action: :update, domain: Catalog)
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.woo_product_id == 500
    assert reloaded.current_label == "Original"
  end

  test "remap introducing parent mismatch is rejected" do
    source = create_source_system!()
    event = create_event!(source)
    ticket_match = create_ticket_type!(event, %{name: "Match", external_product_id: 500})
    ticket_mismatch = create_ticket_type!(event, %{name: "Mismatch", external_product_id: 600})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket_match}, %{
        woo_product_id: 500,
        woo_variation_id: nil
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
    assert reloaded.woo_product_id == 500
  end

  test "variation TicketType with matching external_product_id is allowed" do
    source = create_source_system!()
    event = create_event!(source)

    ticket =
      create_ticket_type!(event, %{
        name: "Variation",
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
  end

  test "unrelated metadata update on valid mapping still succeeds" do
    source = create_source_system!()
    event = create_event!(source)
    ticket = create_ticket_type!(event, %{external_product_id: 500})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil,
        current_label: "Before"
      })

    drain_side_effect_messages()

    updated =
      Ash.update!(
        mapping,
        %{current_label: "After"},
        action: :update,
        domain: Catalog
      )

    assert updated.current_label == "After"
    assert updated.woo_product_id == 500
    assert updated.ticket_type_id == ticket.id
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
