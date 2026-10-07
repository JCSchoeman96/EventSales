defmodule EventSales.Analytics.PeriodComparisonReaderTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period comparison"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_user!("period-compare-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    %{
      source: source,
      event: event,
      ticket: ticket,
      admin: admin,
      currency: "ZAR"
    }
  end

  test "yesterday comparison derives event metrics from Johannesburg day buckets", ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket,
      ctx.currency,
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 4, gross_ticket_value: Decimal.new("40.00")},
        previous: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")}
      }
    )

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, ctx.currency, :yesterday,
               actor: ctx.admin,
               now: @now
             )

    assert result.current.readiness == :ready
    assert result.comparison.readiness == :ready
    assert result.current.metrics.net_ticket_quantity == Decimal.new("4")
    assert result.comparison.metrics.net_ticket_quantity == Decimal.new("2")

    gross = result.event.metric_comparisons.gross_ticket_quantity
    assert gross.state == :available
    assert Decimal.equal?(gross.absolute_delta, Decimal.new("2"))
    row = hd(result.dimensions.ticket_type)
    assert row.metric_comparisons.gross_ticket_quantity.state == :available
    assert row.identity == {:ticket_type, ctx.ticket.id}
  end

  test "analytics not ready fails closed without projection reads", ctx do
    other = SalesHelpers.create_event!(ctx.source, %{name: "Not ready"})

    {result, queries} =
      capture_select_queries(fn ->
        PeriodComparisonReader.compare_event(other.id, ctx.currency, :yesterday,
          actor: ctx.admin,
          now: @now
        )
      end)

    assert {:ok, envelope} = result
    refute envelope.analytics_ready?
    assert envelope.blocking_reason != nil
    assert envelope.event.metric_comparisons.gross_ticket_quantity.state == :current_missing
    refute Enum.any?(queries, &String.contains?(&1, "analytics_event_period_aggregate_snapshots"))
  end

  test "invalid uuid is rejected before auth work", %{admin: admin} do
    assert {:error, {:invalid_uuid, :event_id}} =
             PeriodComparisonReader.compare_event("not-a-uuid", "ZAR", :yesterday, actor: admin)
  end

  test "unsupported period returns before readiness", %{event: event, admin: admin} do
    assert {:error, :unsupported_comparison_period} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :custom, actor: admin)
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Comparison User",
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
