defmodule EventSales.Analytics.PeriodComparisonReaderPolicyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{EventAccessGrant, Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.EventDashboardSetting
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period policy"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    owner = create_user!("period-owner@example.com")
    staff = create_user!("period-staff@example.com")
    admin = create_user!("period-admin@example.com")

    create_global_role!(admin, :admin)
    create_event_grant!(owner, event.id, :event_owner)
    create_event_grant!(staff, event.id, :event_staff)

    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("22.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("11.00")}
      }
    )

    %{
      source: source,
      event: event,
      owner: owner,
      staff: staff,
      admin: admin
    }
  end

  test "admin sees revenue on operands and comparisons", %{event: event, admin: admin} do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: admin,
               now: @now
             )

    assert result.revenue_visible?
    assert %Decimal{} = result.current.metrics.gross_ticket_value
    assert %Decimal{} = result.event.metric_comparisons.gross_ticket_value.current
  end

  @monetary_metrics [
    :gross_ticket_value,
    :refund_ticket_value,
    :net_ticket_value,
    :average_ticket_value
  ]

  @quantity_metrics [:gross_ticket_quantity, :refund_ticket_quantity, :net_ticket_quantity]

  test "hidden revenue redacts every monetary comparison surface", %{event: event, owner: owner} do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: owner,
               now: @now
             )

    refute result.revenue_visible?

    for metric <- @monetary_metrics do
      assert result.current.metrics[metric] == nil
      assert result.comparison.metrics[metric] == nil
      assert_monetary_comparison_redacted!(result.event.metric_comparisons[metric])
    end

    for metric <- @quantity_metrics do
      assert result.current.metrics[metric] != nil
      assert result.comparison.metrics[metric] != nil
      assert result.event.metric_comparisons[metric].state != nil
    end

    for kind <- [:ticket_type, :source_product, :source_variation] do
      row = hd(Map.fetch!(result.dimensions, kind))

      for metric <- @monetary_metrics do
        assert_monetary_comparison_redacted!(row.metric_comparisons[metric])
      end

      for metric <- @quantity_metrics do
        assert row.metric_comparisons[metric].state != nil
      end
    end
  end

  test "global analytics not ready redacts monetary comparison state for revenue-hidden actor", %{
    source: source,
    owner: owner
  } do
    event = SalesHelpers.create_event!(source, %{name: "Global not ready revenue"})
    create_event_grant!(owner, event.id, :event_owner)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: owner,
               now: @now
             )

    refute result.analytics_ready?
    assert result.current.readiness == :not_ready

    assert result.event.metric_comparisons.gross_ticket_quantity.state == :current_missing

    for metric <- @monetary_metrics do
      assert_monetary_comparison_redacted!(result.event.metric_comparisons[metric])
    end
  end

  test "owner hides monetary metrics by default", %{event: event, owner: owner} do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: owner,
               now: @now
             )

    refute result.revenue_visible?
    assert result.current.metrics.gross_ticket_quantity == Decimal.new("2")
    assert result.current.metrics.gross_ticket_value == nil
    assert result.current.metrics.average_ticket_value == nil

    monetary = result.event.metric_comparisons.gross_ticket_value
    assert monetary.current == nil
    assert monetary.comparison == nil
    assert monetary.state == nil
  end

  test "dashboard settings can expose revenue to owner and staff", %{
    event: event,
    owner: owner,
    staff: staff
  } do
    create_dashboard_setting!(event, %{
      revenue_visible_to_event_owner: true,
      revenue_visible_to_event_staff: false
    })

    assert {:ok, owner_result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: owner,
               now: @now
             )

    assert owner_result.revenue_visible?

    assert {:ok, staff_result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: staff,
               now: @now
             )

    refute staff_result.revenue_visible?
    assert staff_result.event.metric_comparisons.net_ticket_value.current == nil
  end

  test "forbidden actor never reaches projection tables", %{event: event} do
    stranger = create_user!("period-stranger@example.com")

    {result, queries} =
      capture_select_queries(fn ->
        PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
          actor: stranger,
          now: @now
        )
      end)

    assert {:error, :forbidden} = result
    refute Enum.any?(queries, &String.contains?(&1, "analytics_event_period_aggregate_snapshots"))
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Policy User",
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

  defp create_event_grant!(user, event_id, role, attrs \\ []) do
    Ash.create!(
      EventAccessGrant,
      Map.merge(%{user_id: user.id, event_id: event_id, role: role}, Map.new(attrs)),
      action: :create,
      domain: Accounts
    )
  end

  defp create_dashboard_setting!(event, attrs) do
    Ash.create!(
      EventDashboardSetting,
      Map.merge(
        %{
          event_id: event.id,
          revenue_visible_to_event_owner: false,
          revenue_visible_to_event_staff: false,
          order_numbers_visible: false,
          pii_visible: false
        },
        Map.new(attrs)
      ),
      action: :create,
      domain: Catalog
    )
  end

  defp assert_monetary_comparison_redacted!(comparison) do
    assert comparison.current == nil
    assert comparison.comparison == nil
    assert comparison.state == nil
    assert comparison.absolute_delta == nil
    assert comparison.percentage_delta == nil
  end

  defp capture_select_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        EventSales.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, metadata.query})
        end,
        {parent, handler_id}
      )

    try do
      result = fun.()
      {result, collect_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_queries(handler_id, acc) do
    receive do
      {^handler_id, sql} -> collect_queries(handler_id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
