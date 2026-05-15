defmodule EventSales.Catalog.CatalogResourcesProductMappingTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Accounts
  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.EventAccessGrant
  alias EventSales.Accounts.Resources.Role
  alias EventSales.Accounts.Resources.User
  alias EventSales.Accounts.Resources.UserRole
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.EventDashboardSetting
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.Resources.TicketType
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.Repo
  alias EventSales.Telemetry

  setup do
    handler_id = "catalog-cache-invalidate-test-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.cache_invalidate(),
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "event belongs to source system" do
    source = create_source_system!()
    event = create_event!(source, %{name: "Summer", slug: "summer"})

    loaded = Ash.load!(event, :source_system, domain: Catalog)
    assert loaded.source_system.id == source.id
  end

  test "ticket type belongs to event" do
    source = create_source_system!()
    event = create_event!(source, %{name: "Summer", slug: "summer"})
    ticket = create_ticket_type!(event, %{name: "GA"})

    loaded = Ash.load!(ticket, :event, domain: Catalog)
    assert loaded.event.id == event.id
  end

  test "product mapping supports product and optional variation" do
    ctx = mapping_context!()

    product_level =
      create_mapping!(ctx, %{woo_product_id: 100, woo_variation_id: nil, current_label: "GA"})

    variation_level =
      create_mapping!(ctx, %{
        woo_product_id: 200,
        woo_variation_id: 501,
        current_label: "VIP"
      })

    assert product_level.woo_variation_id == nil
    assert variation_level.woo_variation_id == 501
  end

  test "capacity may be nil on event and ticket type" do
    source = create_source_system!()

    event =
      create_event!(source, %{
        name: "Open Capacity",
        slug: "open-capacity",
        capacity: nil
      })

    ticket = create_ticket_type!(event, %{name: "Standing", capacity: nil})

    assert event.capacity == nil
    assert ticket.capacity == nil
  end

  test "dashboard settings store revenue visibility flags" do
    source = create_source_system!()
    event = create_event!(source, %{name: "Revenue Event", slug: "revenue-event"})

    setting =
      Ash.create!(
        EventDashboardSetting,
        %{
          event_id: event.id,
          revenue_visible_to_event_owner: true,
          revenue_visible_to_event_staff: false,
          order_numbers_visible: true,
          pii_visible: false
        },
        action: :create,
        domain: Catalog
      )

    assert setting.revenue_visible_to_event_owner
    refute setting.revenue_visible_to_event_staff
    assert setting.order_numbers_visible
    refute setting.pii_visible
  end

  test "source system base_url normalizes trailing slash and rejects duplicates" do
    first =
      Ash.create!(
        SourceSystem,
        %{
          name: "Store A",
          kind: :woocommerce,
          base_url: "https://woocommerce.example.test/"
        },
        action: :create,
        domain: Catalog
      )

    assert first.base_url == "https://woocommerce.example.test"

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        SourceSystem,
        %{
          name: "Store B",
          kind: :woocommerce,
          base_url: "https://woocommerce.example.test"
        },
        action: :create,
        domain: Catalog
      )
    end
  end

  test "duplicate active mapping is rejected without side effects" do
    ctx = mapping_context!()

    create_mapping!(ctx, %{woo_product_id: 900, woo_variation_id: nil})

    assert_enqueued(worker: MappingChangedWorker, args: %{"event_id" => ctx.event.id})

    assert_raise Ash.Error.Invalid, fn ->
      create_mapping!(ctx, %{woo_product_id: 900, woo_variation_id: nil, current_label: "Dup"})
    end

    assert mapping_worker_count() == 1
    assert_received_telemetry_count(1)
  end

  test "inactive historical mapping allows new active mapping after deactivate" do
    source = create_source_system!()
    event_a = create_event!(source, %{name: "Event A", slug: "event-a"})
    event_b = create_event!(source, %{name: "Event B", slug: "event-b"})
    ticket_a = create_ticket_type!(event_a, %{name: "GA A"})
    ticket_b = create_ticket_type!(event_b, %{name: "GA B"})

    first =
      create_mapping!(%{source: source, event: event_a, ticket: ticket_a}, %{
        woo_product_id: 777,
        woo_variation_id: nil
      })

    Ash.update!(first, %{}, action: :deactivate, domain: Catalog)

    second =
      create_mapping!(%{source: source, event: event_b, ticket: ticket_b}, %{
        woo_product_id: 777,
        woo_variation_id: nil
      })

    assert second.active
    refute Ash.get!(ProductMapping, first.id, domain: Catalog).active
  end

  test "ticket_type_id must belong to the same event_id as the mapping" do
    source = create_source_system!()
    event_a = create_event!(source, %{name: "Event A", slug: "event-a-2"})
    event_b = create_event!(source, %{name: "Event B", slug: "event-b-2"})
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
          original_label: "Bad",
          current_label: "Bad"
        },
        action: :create,
        domain: Catalog
      )
    end

    assert mapping_row_count() == before_count
    refute_enqueued(worker: MappingChangedWorker)
  end

  test "successful mapping update enqueues job and emits telemetry including label-only" do
    ctx = mapping_context!()
    mapping = create_mapping!(ctx, %{woo_product_id: 300, woo_variation_id: nil})

    drain_side_effect_messages()

    Ash.update!(mapping, %{current_label: "Renamed label"}, action: :update, domain: Catalog)

    assert_enqueued(worker: MappingChangedWorker, args: %{"event_id" => ctx.event.id})
    cache_event = Telemetry.cache_invalidate()

    assert_received {:telemetry, ^cache_event, %{count: 1},
                     %{event_id: event_id, reason: :mapping_changed}}
                    when event_id == ctx.event.id
  end

  test "product mapping update creates a paper trail version" do
    ctx = mapping_context!()
    mapping = create_mapping!(ctx, %{woo_product_id: 400, woo_variation_id: nil})

    drain_side_effect_messages()

    updated =
      Ash.update!(mapping, %{current_label: "After"}, action: :update, domain: Catalog)

    loaded = Ash.load!(updated, :paper_trail_versions, domain: Catalog)
    assert length(loaded.paper_trail_versions) == 1
  end

  test "revenue visibility uses dashboard settings and grants" do
    source = create_source_system!()
    event = create_event!(source, %{name: "Policy Event", slug: "policy-event"})

    admin = create_user!("catalog-admin@example.com")
    owner = create_user!("catalog-owner@example.com")
    staff = create_user!("catalog-staff@example.com")

    create_global_role!(admin, :admin)
    create_event_grant!(owner, event.id, :event_owner)
    create_event_grant!(staff, event.id, :event_staff)

    refute Policies.can_view_revenue?(owner, event.id)
    refute Policies.can_view_revenue?(staff, event.id)

    Ash.create!(
      EventDashboardSetting,
      %{
        event_id: event.id,
        revenue_visible_to_event_owner: true,
        revenue_visible_to_event_staff: true
      },
      action: :create,
      domain: Catalog
    )

    assert Policies.can_view_revenue?(admin, event.id)
    assert Policies.can_view_revenue?(owner, event.id)
    assert Policies.can_view_revenue?(staff, event.id)
  end

  defp mapping_context! do
    source = create_source_system!()
    event = create_event!(source, %{name: "Mapped Event", slug: "mapped-event"})
    ticket = create_ticket_type!(event, %{name: "GA"})
    %{source: source, event: event, ticket: ticket}
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

  defp mapping_worker_count do
    from(j in Oban.Job, where: j.worker == ^mapping_worker(), select: count(j.id))
    |> Repo.one!()
  end

  defp drain_side_effect_messages do
    flush_telemetry_messages()

    from(j in Oban.Job, where: j.worker == ^mapping_worker())
    |> Repo.delete_all()
  end

  defp flush_telemetry_messages do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry_messages()
    after
      0 -> :ok
    end
  end

  defp assert_received_telemetry_count(expected) do
    cache_event = Telemetry.cache_invalidate()

    count =
      Enum.reduce(1..expected, 0, fn _, acc ->
        receive do
          {:telemetry, ^cache_event, _, _} -> acc + 1
        after
          100 -> acc
        end
      end)

    assert count == expected
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Test User",
        password: password,
        password_confirmation: password
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role = Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)

    Ash.create!(
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp create_event_grant!(user, event_id, role, opts \\ []) do
    attrs =
      %{
        user_id: user.id,
        event_id: event_id,
        role: role
      }
      |> Map.merge(Map.new(opts))

    Ash.create!(EventAccessGrant, attrs, action: :create, domain: Accounts)
  end
end
