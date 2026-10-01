defmodule EventSales.Analytics.DimensionSnapshotReaderPolicyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{EventAccessGrant, Role, User, UserRole}
  alias EventSales.Analytics.DimensionSnapshotReader
  alias EventSales.Analytics.Resources.{EventAggregateSnapshot, EventDimensionAggregateSnapshot}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.EventDashboardSetting
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @refreshed_at ~U[2026-05-22 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Policy Event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Policy Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    owner = create_user!("dimension-owner@example.com")
    event_staff = create_user!("dimension-staff@example.com")
    unassigned = create_user!("dimension-unassigned@example.com")
    global_staff = create_user!("dimension-global-staff@example.com")
    admin = create_user!("dimension-admin@example.com")

    create_global_role!(global_staff, :staff)
    create_global_role!(admin, :admin)

    seed_ready_projection!(event, source, ticket)

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      owner: owner,
      event_staff: event_staff,
      unassigned: unassigned,
      global_staff: global_staff,
      admin: admin
    }
  end

  test "global admin sees revenue", %{event: event, admin: admin} do
    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    assert result.revenue_visible?
    row = hd(hd(result.currencies).dimensions.ticket_type)
    assert %Decimal{} = row.gross_ticket_value
    assert %Decimal{} = row.refund_ticket_value
    assert %Decimal{} = row.net_ticket_value
    assert row.average_ticket_value == nil or match?(%Decimal{}, row.average_ticket_value)
  end

  test "event owner hides revenue by default", %{event: event, owner: owner} do
    create_event_grant!(owner, event.id, :event_owner)

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: owner)
    refute result.revenue_visible?
    row = hd(hd(result.currencies).dimensions.ticket_type)
    assert row.gross_ticket_quantity > 0
    assert row.refund_ticket_quantity >= 0
    assert row.net_ticket_quantity > 0
    assert row.gross_ticket_value == nil
    assert row.refund_ticket_value == nil
    assert row.net_ticket_value == nil
    assert row.average_ticket_value == nil
  end

  test "event owner and staff revenue follows dashboard settings", %{
    event: event,
    owner: owner,
    event_staff: event_staff
  } do
    create_event_grant!(owner, event.id, :event_owner)
    create_event_grant!(event_staff, event.id, :event_staff)

    create_dashboard_setting!(event, %{
      revenue_visible_to_event_owner: true,
      revenue_visible_to_event_staff: false
    })

    assert {:ok, owner_result} = DimensionSnapshotReader.list_for_event(event.id, actor: owner)
    assert owner_result.revenue_visible?

    assert {:ok, staff_result} =
             DimensionSnapshotReader.list_for_event(event.id, actor: event_staff)

    refute staff_result.revenue_visible?
    staff_row = hd(hd(staff_result.currencies).dimensions.ticket_type)
    assert staff_row.gross_ticket_value == nil
    assert staff_row.refund_ticket_value == nil
    assert staff_row.net_ticket_value == nil
    assert staff_row.average_ticket_value == nil

    update_dashboard_setting!(event, %{revenue_visible_to_event_staff: true})

    assert {:ok, visible_staff} =
             DimensionSnapshotReader.list_for_event(event.id, actor: event_staff)

    assert visible_staff.revenue_visible?
  end

  test "unassigned and global staff without grant are forbidden", %{
    event: event,
    unassigned: unassigned,
    global_staff: global_staff
  } do
    assert {:error, :forbidden} =
             DimensionSnapshotReader.list_for_event(event.id, actor: unassigned)

    assert {:error, :forbidden} =
             DimensionSnapshotReader.list_for_event(event.id, actor: global_staff)
  end

  test "expired grant is forbidden", %{event: event, owner: owner} do
    create_event_grant!(owner, event.id, :event_owner,
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    )

    assert {:error, :forbidden} = DimensionSnapshotReader.list_for_event(event.id, actor: owner)
  end

  test "nil actor is forbidden", %{event: event} do
    assert {:error, :forbidden} = DimensionSnapshotReader.list_for_event(event.id, actor: nil)
  end

  test "unassigned unknown valid uuid is forbidden before event or projection reads", %{
    unassigned: unassigned
  } do
    unknown_event_id = Ecto.UUID.generate()

    {result, queries} =
      capture_queries(fn ->
        DimensionSnapshotReader.list_for_event(unknown_event_id, actor: unassigned)
      end)

    assert {:error, :forbidden} = result

    counts = projection_existence_query_counts(queries)
    assert counts.catalog_events == 0
    assert counts.event_v2 == 0
    assert counts.dimensions == 0
  end

  test "unassigned valid uuid is forbidden before dimension projection is read", %{
    event: event,
    unassigned: unassigned
  } do
    {result, queries} =
      capture_queries(fn ->
        DimensionSnapshotReader.list_for_event(event.id, actor: unassigned)
      end)

    assert {:error, :forbidden} = result

    refute Enum.any?(
             queries,
             &String.contains?(&1, "analytics_event_dimension_aggregate_snapshots")
           )
  end

  test "owner cannot read other events", %{event: event, other_event: other_event, owner: owner} do
    create_event_grant!(owner, event.id, :event_owner)

    assert {:ok, _} = DimensionSnapshotReader.list_for_event(event.id, actor: owner)

    assert {:error, :forbidden} =
             DimensionSnapshotReader.list_for_event(other_event.id, actor: owner)
  end

  test "unknown event is not_found only after authorization", %{admin: admin, owner: owner} do
    unknown_event_id = Ecto.UUID.generate()
    create_event_grant!(owner, unknown_event_id, :event_owner)

    assert :not_found = DimensionSnapshotReader.list_for_event(unknown_event_id, actor: admin)
    assert :not_found = DimensionSnapshotReader.list_for_event(unknown_event_id, actor: owner)
  end

  defp seed_ready_projection!(event, source, ticket) do
    Ash.create!(
      EventAggregateSnapshot,
      %{
        event_id: event.id,
        total_sold: 2,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0"),
        gross_ticket_quantity: 2,
        refund_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("22.00"),
        refund_ticket_value: Decimal.new("0"),
        recognised_order_count: 1,
        currency: "ZAR",
        business_timezone: "Africa/Johannesburg",
        refreshed_at: @refreshed_at,
        source_row_count: 0,
        snapshot_version: 2
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )

    Ash.create!(
      EventDimensionAggregateSnapshot,
      %{
        event_id: event.id,
        currency: "ZAR",
        dimension_kind: :ticket_type,
        ticket_type_id: ticket.id,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("22.00"),
        refreshed_at: @refreshed_at
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )

    Ash.create!(
      EventDimensionAggregateSnapshot,
      %{
        event_id: event.id,
        currency: "ZAR",
        dimension_kind: :source_product,
        source_system_id: source.id,
        woo_product_id: 42,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("22.00"),
        refreshed_at: @refreshed_at
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Dimension Policy User",
        password: "valid-pass-123",
        password_confirmation: "valid-pass-123"
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp create_event_grant!(user, event_id, role, opts \\ []) do
    attrs =
      %{user_id: user.id, event_id: event_id, role: role}
      |> Map.merge(Map.new(opts))

    Ash.create!(EventAccessGrant, attrs, action: :create, domain: Accounts)
  end

  defp create_dashboard_setting!(event, attrs) do
    defaults = %{
      event_id: event.id,
      revenue_visible_to_event_owner: false,
      revenue_visible_to_event_staff: false,
      order_numbers_visible: false,
      pii_visible: false
    }

    Ash.create!(EventDashboardSetting, Map.merge(defaults, Map.new(attrs)),
      action: :create,
      domain: Catalog
    )
  end

  defp update_dashboard_setting!(event, attrs) do
    EventDashboardSetting
    |> Ash.Query.filter(event_id == ^event.id)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.update!(Map.new(attrs), action: :update, domain: Catalog)
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, inspect(metadata.query)})
        end,
        {parent, handler_id}
      )

    result = fun.()

    try do
      {result, collect_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> collect_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp projection_existence_query_counts(queries) do
    relevant =
      Enum.reject(queries, fn query ->
        String.match?(query, ~r/\b(BEGIN|COMMIT|ROLLBACK)\b/i)
      end)

    %{
      catalog_events: count_table_queries(relevant, "catalog_events"),
      event_v2: count_table_queries(relevant, "analytics_event_aggregate_snapshots"),
      dimensions: count_table_queries(relevant, "analytics_event_dimension_aggregate_snapshots")
    }
  end

  defp count_table_queries(queries, table) do
    Enum.count(queries, &String.contains?(&1, table))
  end
end
