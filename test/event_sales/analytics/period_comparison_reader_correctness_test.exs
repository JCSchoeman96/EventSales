defmodule EventSales.Analytics.PeriodComparisonReaderCorrectnessTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.Resources.{AnalyticsContributionFact, EventPeriodAggregateSnapshot}
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:17:33.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Correctness event"})
    ticket_a = SalesHelpers.create_ticket_type!(event, %{name: "GA-A"})
    ticket_b = SalesHelpers.create_ticket_type!(event, %{name: "GA-B"})
    admin = create_user!("period-correctness-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    %{source: source, event: event, ticket_a: ticket_a, ticket_b: ticket_b, admin: admin}
  end

  test "dimensional ticket_type absent in ready previous with current activity yields new_activity",
       ctx do
    PeriodComparisonHelpers.seed_asymmetric_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      ctx.ticket_b,
      "ZAR",
      :yesterday,
      @now,
      %{
        previous: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")},
        current: %{gross_ticket_quantity: 5, gross_ticket_value: Decimal.new("50.00")}
      }
    )

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    row =
      Enum.find(result.dimensions.ticket_type, fn row ->
        row.identity == {:ticket_type, ctx.ticket_b.id}
      end)

    qty = row.metric_comparisons.gross_ticket_quantity
    assert qty.state == :new_activity
    assert Decimal.equal?(qty.comparison, Decimal.new("0"))
    assert Decimal.equal?(qty.current, Decimal.new("5"))
    assert qty.percentage_delta == nil
  end

  test "dimensional source_product absent in ready previous with current activity yields new_activity",
       ctx do
    PeriodComparisonHelpers.seed_asymmetric_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      ctx.ticket_b,
      "ZAR",
      :yesterday,
      @now,
      %{
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")},
        current: %{gross_ticket_quantity: 0, gross_ticket_value: Decimal.new("0")}
      }
    )

    {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:yesterday, @now)
    current_plan = Enum.find(plan.operands, &(&1.operand == :current))

    Enum.each(current_plan.fixed_buckets, fn spec ->
      event_row =
        EventPeriodAggregateSnapshot
        |> Ash.Query.filter(
          event_id == ^ctx.event.id and currency == ^"ZAR" and bucket_kind == ^spec.bucket_kind and
            bucket_start_utc == ^spec.bucket_start_utc and bucket_end_utc == ^spec.bucket_end_utc
        )
        |> Ash.read_one!(domain: Analytics)

      Ash.update!(
        event_row,
        %{
          gross_ticket_quantity: 4,
          gross_ticket_value: Decimal.new("40.00")
        },
        action: :update_snapshot,
        domain: Analytics
      )

      PeriodComparisonHelpers.create_dimension_bucket!(
        event_row,
        ctx.source,
        ctx.ticket_b,
        :ticket_type,
        %{
          gross_ticket_quantity: 4,
          gross_ticket_value: Decimal.new("40.00")
        }
      )

      PeriodComparisonHelpers.create_dimension_bucket!(
        event_row,
        ctx.source,
        ctx.ticket_b,
        :source_product,
        %{
          woo_product_id: 82_002,
          gross_ticket_quantity: 4,
          gross_ticket_value: Decimal.new("40.00")
        }
      )
    end)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    row =
      Enum.find(result.dimensions.source_product, fn row ->
        row.identity == {:source_product, ctx.source.id, 82_002}
      end)

    qty = row.metric_comparisons.gross_ticket_quantity
    assert qty.state == :new_activity
    assert Decimal.equal?(qty.comparison, Decimal.new("0"))
    assert Decimal.equal?(qty.current, Decimal.new("4"))
  end

  test "dimensional flat_zero when ready comparison and current grains are both zero", ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:yesterday, @now)

    for operand_plan <- plan.operands,
        spec <- operand_plan.fixed_buckets do
      event_row =
        EventPeriodAggregateSnapshot
        |> Ash.Query.filter(
          event_id == ^ctx.event.id and currency == ^"ZAR" and bucket_kind == ^spec.bucket_kind and
            bucket_start_utc == ^spec.bucket_start_utc and bucket_end_utc == ^spec.bucket_end_utc
        )
        |> Ash.read_one!(domain: Analytics)

      PeriodComparisonHelpers.create_dimension_bucket!(
        event_row,
        ctx.source,
        ctx.ticket_b,
        :ticket_type,
        %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          refund_ticket_quantity: 0,
          refund_ticket_value: Decimal.new("0")
        }
      )
    end

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    row =
      Enum.find(result.dimensions.ticket_type, fn row ->
        row.identity == {:ticket_type, ctx.ticket_b.id}
      end)

    qty = row.metric_comparisons.gross_ticket_quantity
    assert qty.state == :flat_zero
    assert Decimal.equal?(qty.current, Decimal.new("0"))
    assert Decimal.equal?(qty.comparison, Decimal.new("0"))
  end

  test "ready previous absent grain with current activity yields new_activity", ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 4, gross_ticket_value: Decimal.new("40.00")},
        previous: %{gross_ticket_quantity: 0, gross_ticket_value: Decimal.new("0")}
      }
    )

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    qty = result.event.metric_comparisons.gross_ticket_quantity
    assert qty.state == :new_activity
    assert Decimal.equal?(qty.current, Decimal.new("4"))
    assert Decimal.equal?(qty.comparison, Decimal.new("0"))
  end

  test "undefined ATV comparison state stays nil when operands are undefined", ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 0, gross_ticket_value: Decimal.new("0")},
        previous: %{gross_ticket_quantity: 0, gross_ticket_value: Decimal.new("0")}
      }
    )

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    atv = result.event.metric_comparisons.average_ticket_value
    assert atv.current == nil
    assert atv.comparison == nil
    assert atv.state == nil
    assert atv.absolute_delta == nil
    assert atv.percentage_delta == nil
  end

  test "edge metadata mismatch fails closed for the operand", ctx do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :today,
      @now,
      %{
        current: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: %{
            default: [%{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}]
          }
        },
        previous: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: %{
            default: [%{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("5.00")}]
          }
        }
      }
    )

    AnalyticsContributionFact
    |> Ash.Query.filter(event_id == ^ctx.event.id)
    |> Ash.read!(domain: Analytics)
    |> Enum.each(fn fact ->
      Ash.update!(fact, %{semantic_version: 2}, action: :update_fact, domain: Analytics)
    end)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
               actor: ctx.admin,
               now: @now
             )

    assert result.current.readiness == :not_ready
    assert result.event.metric_comparisons.gross_ticket_quantity.state == :current_missing
  end

  test "mixed operand coverage identity fails closed", ctx do
    {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:today, @now)
    current_plan = Enum.find(plan.operands, &(&1.operand == :current))

    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :today,
      @now,
      %{
        current: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: %{
            default: [%{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")}]
          }
        },
        previous: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: %{
            default: [%{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}]
          }
        }
      }
    )

    envelope_hour =
      current_plan.edge_fragments
      |> hd()
      |> Map.fetch!(:envelope_hour_start_utc)

    row =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^ctx.event.id and currency == ^"ZAR" and bucket_start_utc == ^envelope_hour
      )
      |> Ash.read_one!(domain: Analytics)

    Ash.update!(row, %{coverage_identity: "other_coverage_v2"},
      action: :update_snapshot,
      domain: Analytics
    )

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
               actor: ctx.admin,
               now: @now
             )

    assert result.current.readiness == :not_ready
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Correctness User",
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
