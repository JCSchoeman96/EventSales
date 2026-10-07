defmodule EventSales.Analytics.PeriodCoverageGapTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:00:00.000000Z]
  @later ~U[2026-05-17 11:30:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Coverage gap"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_user!("period-gap-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")

    %{source: source, event: event, ticket: ticket, admin: admin}
  end

  test "analytics-ready event without period rows is not comparable (absent != zero)", ctx do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    assert result.current.readiness == :not_ready
    assert result.event.metric_comparisons.gross_ticket_quantity.state == :current_missing
    refute event_period_row_exists?(ctx.event.id, "ZAR", :yesterday, @now, :current)
  end

  test "yesterday-only seed leaves rolling30 interior hours absent without explicit CURRENT zero",
       ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for({:rolling_days, 30}, @now)
    current_plan = Enum.find(plan.operands, &(&1.operand == :current))

    missing_interior =
      Enum.find(current_plan.fixed_buckets, fn spec ->
        spec.bucket_kind == :utc_hour and
          not event_period_row_exists_for_spec?(ctx.event.id, "ZAR", spec)
      end)

    assert missing_interior != nil

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", {:rolling_days, 30},
               actor: ctx.admin,
               now: @now
             )

    refute result.current.readiness == :ready
  end

  test "moving horizon: complete today projection becomes current_missing in next empty hour",
       ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket,
      "ZAR",
      :today,
      @now,
      %{
        current: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    assert {:ok, ready_at_now} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
               actor: ctx.admin,
               now: @now
             )

    assert ready_at_now.current.readiness == :ready

    assert {:ok, after_hour} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
               actor: ctx.admin,
               now: @later
             )

    assert after_hour.current.readiness == :not_ready
    assert after_hour.event.metric_comparisons.gross_ticket_quantity.state == :current_missing
  end

  defp event_period_row_exists?(event_id, currency, request, now, state) do
    {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(request, now)
    current_plan = Enum.find(plan.operands, &(&1.operand == :current))
    spec = hd(current_plan.fixed_buckets)

    case row_for_spec(event_id, currency, spec) do
      nil -> false
      row -> row.projection_state == state
    end
  end

  defp event_period_row_exists_for_spec?(event_id, currency, spec) do
    row_for_spec(event_id, currency, spec) != nil
  end

  defp row_for_spec(event_id, currency, spec) do
    EventPeriodAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and currency == ^currency and bucket_kind == ^spec.bucket_kind and
        bucket_start_utc == ^spec.bucket_start_utc and bucket_end_utc == ^spec.bucket_end_utc
    )
    |> Ash.read_one(domain: EventSales.Analytics)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Gap User",
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
end
