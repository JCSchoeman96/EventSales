defmodule EventSales.Analytics.EventScopedDashboardTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{EventAccessGrant, Role, User, UserRole}
  alias EventSales.Analytics.{DashboardCache, EventScopedDashboard, HotStateAggregator}
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.EventDashboardSetting
  alias EventSales.TestSupport.SalesHelpers

  setup do
    HotStateAggregator.reset_for_test!()

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Scoped Event", slug: unique_slug("scoped")})

    other_event =
      SalesHelpers.create_event!(source, %{name: "Other Event", slug: unique_slug("other")})

    owner = create_user!("dashboard-owner@example.com")
    event_staff = create_user!("dashboard-event-staff@example.com")
    unassigned = create_user!("dashboard-unassigned@example.com")
    global_staff = create_user!("dashboard-global-staff@example.com")
    admin = create_user!("dashboard-admin@example.com")

    create_global_role!(global_staff, :staff)
    create_global_role!(admin, :admin)

    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    %{
      source: source,
      event: event,
      other_event: other_event,
      owner: owner,
      event_staff: event_staff,
      unassigned: unassigned,
      global_staff: global_staff,
      admin: admin
    }
  end

  test "event owner assigned aggregate access reads the assigned event only", %{
    event: event,
    other_event: other_event,
    owner: owner
  } do
    create_event_grant!(owner, event.id, :event_owner)
    create_snapshot!(event, %{total_sold: 4, total_revenue: Decimal.new("1200.00")})

    assert {:ok, summary} = EventScopedDashboard.summary(event.id, actor: owner)
    assert summary.event_id == event.id
    assert summary.total_sold == 4
    refute summary.revenue_visible?
    assert summary.total_revenue == nil
    assert summary.pii_visibility == :none

    assert {:error, :forbidden} = EventScopedDashboard.summary(other_event.id, actor: owner)
  end

  test "unassigned valid UUID is forbidden before event existence is revealed", %{
    unassigned: unassigned
  } do
    unknown_event_id = Ecto.UUID.generate()

    assert {:error, :forbidden} =
             EventScopedDashboard.summary(unknown_event_id, actor: unassigned)
  end

  test "unknown event returns not found only after actor is authorized", %{
    admin: admin,
    owner: owner
  } do
    unknown_event_id = Ecto.UUID.generate()
    create_event_grant!(owner, unknown_event_id, :event_owner)

    assert :not_found = EventScopedDashboard.summary(unknown_event_id, actor: admin)
    assert :not_found = EventScopedDashboard.summary(unknown_event_id, actor: owner)
  end

  test "global staff is denied without an event grant", %{event: event, global_staff: staff} do
    create_snapshot!(event, %{total_sold: 2})

    assert {:error, :forbidden} = EventScopedDashboard.summary(event.id, actor: staff)
  end

  test "global admin can read aggregate without an event grant", %{event: event, admin: admin} do
    create_snapshot!(event, %{total_sold: 5, total_revenue: Decimal.new("1500.00")})

    assert {:ok, summary} = EventScopedDashboard.summary(event.id, actor: admin)
    assert summary.total_sold == 5
    assert summary.revenue_visible?
    assert summary.total_revenue == Decimal.new("1500.00")
  end

  test "event staff can read counts but revenue is hidden by default", %{
    event: event,
    event_staff: event_staff
  } do
    create_event_grant!(event_staff, event.id, :event_staff)
    create_snapshot!(event, %{total_sold: 3, total_revenue: Decimal.new("900.00")})

    assert {:ok, summary} = EventScopedDashboard.summary(event.id, actor: event_staff)
    assert summary.total_sold == 3
    refute summary.revenue_visible?
    assert summary.total_revenue == nil
    assert summary.today_revenue == nil
  end

  test "owner and staff revenue visibility follows dashboard settings", %{
    event: event,
    owner: owner,
    event_staff: event_staff
  } do
    create_event_grant!(owner, event.id, :event_owner)
    create_event_grant!(event_staff, event.id, :event_staff)

    create_snapshot!(event, %{
      total_revenue: Decimal.new("1800.00"),
      today_revenue: Decimal.new("600.00")
    })

    create_dashboard_setting!(event, %{
      revenue_visible_to_event_owner: true,
      revenue_visible_to_event_staff: false
    })

    assert {:ok, owner_summary} = EventScopedDashboard.summary(event.id, actor: owner)
    assert owner_summary.revenue_visible?
    assert owner_summary.total_revenue == Decimal.new("1800.00")
    assert owner_summary.today_revenue == Decimal.new("600.00")

    assert {:ok, staff_summary} = EventScopedDashboard.summary(event.id, actor: event_staff)
    refute staff_summary.revenue_visible?
    assert staff_summary.total_revenue == nil

    update_dashboard_setting!(event, %{revenue_visible_to_event_staff: true})

    assert {:ok, visible_staff_summary} =
             EventScopedDashboard.summary(event.id, actor: event_staff)

    assert visible_staff_summary.revenue_visible?
    assert visible_staff_summary.total_revenue == Decimal.new("1800.00")
  end

  test "missing and expired dashboard settings fail safe by hiding revenue", %{
    event: event,
    other_event: other_event,
    owner: owner
  } do
    create_event_grant!(owner, event.id, :event_owner)
    create_event_grant!(owner, other_event.id, :event_owner)
    create_snapshot!(event, %{total_revenue: Decimal.new("1000.00")})
    create_snapshot!(other_event, %{total_revenue: Decimal.new("2000.00")})

    assert {:ok, missing_setting_summary} = EventScopedDashboard.summary(event.id, actor: owner)
    refute missing_setting_summary.revenue_visible?
    assert missing_setting_summary.total_revenue == nil

    create_dashboard_setting!(other_event, %{
      revenue_visible_to_event_owner: true,
      access_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    assert {:ok, expired_setting_summary} =
             EventScopedDashboard.summary(other_event.id, actor: owner)

    refute expired_setting_summary.revenue_visible?
    assert expired_setting_summary.total_revenue == nil
  end

  test "expired grant is denied", %{event: event, owner: owner} do
    create_event_grant!(owner, event.id, :event_owner,
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    )

    assert {:error, :forbidden} = EventScopedDashboard.summary(event.id, actor: owner)
  end

  test "existing event with no hot or snapshot data returns a safe empty aggregate", %{
    event: event,
    owner: owner
  } do
    create_event_grant!(owner, event.id, :event_owner)

    assert {:ok, summary} = EventScopedDashboard.summary(event.id, actor: owner)
    assert summary.total_sold == 0
    assert summary.total_revenue == nil
    assert summary.today_sold == 0
    assert summary.today_revenue == nil
    assert summary.status_breakdown == %{}
    assert summary.source_row_count == 0
    assert summary.snapshot_version == 1
    assert summary.pii_visibility == :none
  end

  test "hot aggregate is preferred over snapshot and response excludes pii", %{
    event: event,
    admin: admin
  } do
    create_snapshot!(event, %{total_sold: 1, total_revenue: Decimal.new("100.00")})

    assert :ok =
             DashboardCache.put_event_summary(event.id, %{
               total_sold: 9,
               total_revenue: Decimal.new("900.00"),
               today_sold: 3,
               today_revenue: Decimal.new("300.00"),
               status_breakdown: %{"completed" => 3},
               currency: "ZAR",
               refreshed_at: ~U[2026-05-22 08:00:00.000000Z],
               source_watermark_at: ~U[2026-05-22 07:59:00.000000Z],
               source_row_count: 3,
               snapshot_version: 2,
               customer_name: "Private Customer",
               customer_email: "private@example.test",
               order_number: "PRIVATE-1",
               payment_gateway_transaction_id: "txn_private"
             })

    assert {:ok, summary} = EventScopedDashboard.summary(event.id, actor: admin)
    assert summary.total_sold == 9
    assert summary.total_revenue == Decimal.new("900.00")
    assert summary.status_breakdown == %{"completed" => 3}
    assert summary.pii_visibility == :none

    refute Map.has_key?(summary, :customer_name)
    refute Map.has_key?(summary, :customer_email)
    refute Map.has_key?(summary, :order_number)
    refute Map.has_key?(summary, :payment_gateway_transaction_id)
    refute summary |> Map.keys() |> Enum.any?(&(to_string(&1) =~ "customer"))
    refute summary |> Map.keys() |> Enum.any?(&(to_string(&1) =~ "email"))
    refute summary |> Map.keys() |> Enum.any?(&(to_string(&1) =~ "payment"))
    refute summary |> Map.keys() |> Enum.any?(&(to_string(&1) =~ "transaction"))
    refute summary |> Map.keys() |> Enum.any?(&(to_string(&1) =~ "raw"))
  end

  test "invalid event id returns invalid uuid error before authorization" do
    assert {:error, {:invalid_uuid, :event_id}} =
             EventScopedDashboard.summary("not-a-uuid", actor: nil)
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Dashboard Test User",
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

  defp create_snapshot!(event, attrs) do
    defaults = %{
      event_id: event.id,
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{},
      currency: "ZAR",
      business_timezone: "Africa/Johannesburg",
      refreshed_at: ~U[2026-05-22 08:00:00.000000Z],
      source_watermark_at: ~U[2026-05-22 07:55:00.000000Z],
      source_row_count: 0,
      snapshot_version: 1
    }

    Ash.create!(EventAggregateSnapshot, Map.merge(defaults, Map.new(attrs)),
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
