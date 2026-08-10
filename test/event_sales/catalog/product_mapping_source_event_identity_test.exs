defmodule EventSales.Catalog.ProductMappingSourceEventIdentityTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.Resources.TicketType
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.Repo

  test "matching source and event create succeeds" do
    source = create_source_system!()
    event = create_event!(source, %{name: "Same Source Event", slug: "same-source-event"})
    ticket = create_ticket_type!(event, %{name: "GA"})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 500,
        woo_variation_id: nil
      })

    assert mapping.source_system_id == source.id
    assert mapping.event_id == event.id
    assert mapping.ticket_type_id == ticket.id
    assert mapping.woo_product_id == 500
  end

  test "cross-source create is rejected and no mapping is persisted" do
    source_a = create_source_system!()
    source_b = create_source_system!()
    event_b = create_event!(source_b, %{name: "Event B", slug: "event-b"})
    ticket_b = create_ticket_type!(event_b, %{name: "GA B"})

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source_a.id,
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          woo_product_id: 42,
          woo_variation_id: nil,
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

  test "cross-source update is rejected and original mapping remains unchanged" do
    source_a = create_source_system!()
    source_b = create_source_system!()
    event_a = create_event!(source_a, %{name: "Event A", slug: "event-a"})
    ticket_a = create_ticket_type!(event_a, %{name: "GA A"})

    mapping =
      create_mapping!(%{source: source_a, event: event_a, ticket: ticket_a}, %{
        woo_product_id: 700,
        woo_variation_id: nil,
        current_label: "Original"
      })

    drain_side_effect_messages()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(
        mapping,
        %{source_system_id: source_b.id},
        action: :update,
        domain: Catalog
      )
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.source_system_id == source_a.id
    assert reloaded.event_id == event_a.id
    assert reloaded.woo_product_id == 700
    assert reloaded.current_label == "Original"
  end

  test "cross-source remap is rejected" do
    source_a = create_source_system!()
    source_b = create_source_system!()
    event_a = create_event!(source_a, %{name: "Event A", slug: "event-a-remap"})
    event_b = create_event!(source_b, %{name: "Event B", slug: "event-b-remap"})
    ticket_a = create_ticket_type!(event_a, %{name: "GA A"})
    ticket_b = create_ticket_type!(event_b, %{name: "GA B"})

    mapping =
      create_mapping!(%{source: source_a, event: event_a, ticket: ticket_a}, %{
        woo_product_id: 800,
        woo_variation_id: nil
      })

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(
        mapping,
        %{event_id: event_b.id, ticket_type_id: ticket_b.id},
        action: :remap,
        domain: Catalog
      )
    end

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.source_system_id == source_a.id
    assert reloaded.event_id == event_a.id
    assert reloaded.ticket_type_id == ticket_a.id
  end

  test "matching source event and ticket type create succeeds" do
    source = create_source_system!()
    event = create_event!(source, %{name: "Full Match", slug: "full-match"})
    ticket = create_ticket_type!(event, %{name: "VIP"})

    mapping =
      create_mapping!(%{source: source, event: event, ticket: ticket}, %{
        woo_product_id: 900,
        woo_variation_id: 901
      })

    assert mapping.source_system_id == source.id
    assert mapping.event_id == event.id
    assert mapping.ticket_type_id == ticket.id
    assert mapping.woo_variation_id == 901
  end

  test "ticket type event mismatch remains rejected" do
    source = create_source_system!()
    event_a = create_event!(source, %{name: "Event A", slug: "tt-event-a"})
    event_b = create_event!(source, %{name: "Event B", slug: "tt-event-b"})
    ticket_on_a = create_ticket_type!(event_a, %{name: "GA"})

    before_count = mapping_row_count()

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event_b.id,
          ticket_type_id: ticket_on_a.id,
          woo_product_id: 42,
          woo_variation_id: nil,
          original_label: "Bad TT",
          current_label: "Bad TT"
        },
        action: :create,
        domain: Catalog
      )
    end

    assert mapping_row_count() == before_count
    refute_enqueued(worker: MappingChangedWorker)
  end

  test "failed cross-source create does not add a mapping row" do
    source_a = create_source_system!()
    source_b = create_source_system!()
    event_b = create_event!(source_b, %{name: "Event B", slug: "no-row-event-b"})
    ticket_b = create_ticket_type!(event_b, %{name: "GA B"})

    before_count = mapping_row_count()

    result =
      Ash.create(
        ProductMapping,
        %{
          source_system_id: source_a.id,
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          woo_product_id: 55,
          woo_variation_id: nil,
          original_label: "No Row",
          current_label: "No Row"
        },
        action: :create,
        domain: Catalog
      )

    assert {:error, %Ash.Error.Invalid{}} = result
    assert mapping_row_count() == before_count
  end

  defp create_source_system!(attrs \\ %{}) do
    defaults = %{
      name: "Woo Store",
      kind: :woocommerce,
      base_url: "https://store-#{System.unique_integer([:positive])}.example.test"
    }

    Ash.create!(SourceSystem, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_event!(source, attrs) do
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
