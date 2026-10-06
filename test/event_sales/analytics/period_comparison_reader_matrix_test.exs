defmodule EventSales.Analytics.PeriodComparisonReaderMatrixTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics
  alias EventSales.Analytics.{MetricRules, PeriodComparisonReader, PeriodReadPlan, TimeRules}
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @johannesburg MetricRules.business_timezone()
  @now ~U[2026-05-17 10:17:33.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Matrix event"})
    ticket_a = SalesHelpers.create_ticket_type!(event, %{name: "GA-A"})
    ticket_b = SalesHelpers.create_ticket_type!(event, %{name: "GA-B"})
    admin = create_user!("period-matrix-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    %{source: source, event: event, ticket_a: ticket_a, ticket_b: ticket_b, admin: admin}
  end

  describe "JC-310 comparison states" do
    test "current_missing when current operand is not ready", ctx do
      seed_yesterday!(ctx, current: 3, previous: 1)
      stale_current_bucket!(ctx.event.id)

      assert_state!(ctx, :yesterday, :gross_ticket_quantity, :current_missing)
    end

    test "comparison_missing when previous operand is not ready", ctx do
      seed_yesterday!(ctx, current: 3, previous: 1)
      stale_previous_bucket!(ctx.event.id)

      assert_state!(ctx, :yesterday, :gross_ticket_quantity, :comparison_missing)
    end

    test "not_comparable when ready operands have incompatible coverage scope", ctx do
      seed_yesterday!(ctx, current: 3, previous: 1)

      previous_row =
        EventPeriodAggregateSnapshot
        |> Ash.Query.filter(
          event_id == ^ctx.event.id and currency == ^"ZAR" and projection_state == :current
        )
        |> Ash.read!(domain: Analytics)
        |> Enum.sort_by(& &1.bucket_start_utc)
        |> hd()

      other_coverage = "comparison_scope_v2"

      Ash.update!(previous_row, %{coverage_identity: other_coverage},
        action: :update_snapshot,
        domain: Analytics
      )

      alias EventSales.Analytics.Resources.EventDimensionPeriodAggregateSnapshot

      EventDimensionPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^ctx.event.id and currency == ^"ZAR" and
          bucket_start_utc == ^previous_row.bucket_start_utc
      )
      |> Ash.read!(domain: Analytics)
      |> Enum.each(fn row ->
        Ash.update!(row, %{coverage_identity: other_coverage},
          action: :update_snapshot,
          domain: Analytics
        )
      end)

      assert_state!(ctx, :yesterday, :gross_ticket_quantity, :not_comparable)
    end

    test "flat_zero when both operands are ready and metrics are zero", ctx do
      seed_yesterday!(ctx, current: 0, previous: 0)

      assert_state!(ctx, :yesterday, :gross_ticket_quantity, :flat_zero)
    end

    test "new_activity when comparison grain had zero activity and current is positive", ctx do
      seed_yesterday!(ctx, current: 4, previous: 0)

      assert_state!(ctx, :yesterday, :gross_ticket_quantity, :new_activity)
    end

    test "baseline_zero when comparison metric is zero but comparison grain had activity", ctx do
      seed_yesterday_net!(ctx,
        current_net: 5,
        previous_net: 0,
        previous_gross: 10,
        previous_refund: 10
      )

      assert_state!(ctx, :yesterday, :net_ticket_quantity, :baseline_zero)
    end

    test "available when both operands are positive and comparable", ctx do
      seed_yesterday!(ctx, current: 4, previous: 2)

      assert_state!(ctx, :yesterday, :gross_ticket_quantity, :available)
    end
  end

  describe "JC-310 precedence" do
    test "readiness and comparability precede metric states", ctx do
      assert MetricRules.classify_comparison_state(%{
               current_readiness: :not_ready,
               comparison_readiness: :not_ready,
               comparable: false,
               comparison_grain_zero_activity: true,
               current_metric: Decimal.new("1"),
               comparison_metric: Decimal.new("1")
             }) == :current_missing

      assert MetricRules.classify_comparison_state(%{
               current_readiness: :ready,
               comparison_readiness: :not_ready,
               comparable: false,
               comparison_grain_zero_activity: true,
               current_metric: Decimal.new("1"),
               comparison_metric: Decimal.new("0")
             }) == :comparison_missing

      assert MetricRules.classify_comparison_state(%{
               current_readiness: :ready,
               comparison_readiness: :ready,
               comparable: false,
               comparison_grain_zero_activity: true,
               current_metric: Decimal.new("5"),
               comparison_metric: Decimal.new("0")
             }) == :not_comparable

      seed_yesterday!(ctx, current: 0, previous: 0)

      assert {:ok, zero_result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
                 actor: ctx.admin,
                 now: @now
               )

      assert zero_result.event.metric_comparisons.gross_ticket_quantity.state == :flat_zero

      stale_current_bucket!(ctx.event.id)

      assert {:ok, missing_result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
                 actor: ctx.admin,
                 now: @now
               )

      assert missing_result.event.metric_comparisons.gross_ticket_quantity.state ==
               :current_missing
    end
  end

  describe "mixed generation within operand" do
    test "unrelated CURRENT buckets may differ in generation_id while operand stays ready", ctx do
      seed_today_edges!(ctx, current_edge_qty: 1, previous_edge_qty: 1)

      rows =
        EventPeriodAggregateSnapshot
        |> Ash.Query.filter(
          event_id == ^ctx.event.id and currency == ^"ZAR" and bucket_kind == :utc_hour and
            projection_state == :current
        )
        |> Ash.read!(domain: Analytics)

      assert length(rows) >= 2

      generation_ids =
        Enum.map(Enum.take(rows, 2), fn row ->
          updated =
            Ash.update!(row, %{generation_id: Ecto.UUID.generate()},
              action: :update_snapshot,
              domain: Analytics
            )

          updated.generation_id
        end)

      assert length(Enum.uniq(generation_ids)) == 2

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :ready
      assert result.comparison.readiness == :ready
    end
  end

  describe "rolling windows" do
    test "rolling 7 uses exact UTC bounds and composes the full period", ctx do
      assert {:ok, windows} =
               TimeRules.comparison_windows(@johannesburg, @now, {:rolling_days, 7})

      assert {:ok, plan} = PeriodReadPlan.build(windows)

      expected_end = @now
      expected_start = DateTime.add(@now, -7 * 86_400, :second)

      assert DateTime.compare(windows.current.start_utc, expected_start) == :eq
      assert DateTime.compare(windows.current.end_utc, expected_end) == :eq

      current = Enum.find(plan.operands, &(&1.operand == :current))
      assert_covers_operand_period!(windows.current, current)
    end

    test "rolling 30 uses exact UTC bounds and composes the full period", ctx do
      assert {:ok, windows} =
               TimeRules.comparison_windows(@johannesburg, @now, {:rolling_days, 30})

      assert {:ok, plan} = PeriodReadPlan.build(windows)

      expected_start = DateTime.add(@now, -30 * 86_400, :second)
      assert DateTime.compare(windows.current.start_utc, expected_start) == :eq
      assert DateTime.compare(windows.current.end_utc, @now) == :eq

      current = Enum.find(plan.operands, &(&1.operand == :current))
      assert_covers_operand_period!(windows.current, current)
    end
  end

  describe "edge envelope matrix" do
    setup ctx do
      seed_today_edges!(ctx, current_edge_qty: 0, previous_edge_qty: 0)
      {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:today, @now)
      current = Enum.find(plan.operands, &(&1.operand == :current))
      fragment = hd(current.edge_fragments)
      envelope_hour = fragment.envelope_hour_start_utc

      Map.merge(ctx, %{
        plan: plan,
        current_plan: current,
        fragment: fragment,
        envelope_hour: envelope_hour
      })
    end

    test "CURRENT envelope with no facts contributes zero", ctx do
      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :ready
      assert Decimal.equal?(result.current.metrics.gross_ticket_quantity, Decimal.new("0"))
    end

    for {state, expected_readiness} <- [
          {:stale, :not_ready},
          {:refresh_pending, :not_ready},
          {:rebuilding, :not_ready},
          {:unavailable, :not_ready}
        ] do
      test "envelope #{state} without facts is not_ready", ctx do
        set_envelope_state!(ctx, unquote(state))

        assert {:ok, result} =
                 PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                   actor: ctx.admin,
                   now: @now
                 )

        assert result.current.readiness == unquote(expected_readiness)
      end
    end

    test "missing envelope hour without facts is not_ready", ctx do
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^ctx.event.id and
          currency == ^"ZAR" and
          bucket_kind == :utc_hour and
          bucket_start_utc == ^ctx.envelope_hour
      )
      |> Ash.read!(domain: Analytics)
      |> Enum.each(&Ash.destroy!(&1, action: :destroy_snapshot, domain: Analytics))

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :not_ready
    end

    test "edge contribution generation mismatch is allowed when metadata matches", ctx do
      PeriodComparisonHelpers.insert_edge_contribution_fact!(
        ctx.event.id,
        "ZAR",
        ctx.fragment,
        ctx.source,
        ctx.ticket_a,
        %{
          generation_id: Ecto.UUID.generate(),
          gross_ticket_quantity: 2,
          gross_ticket_value: Decimal.new("20.00")
        }
      )

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :ready
      assert Decimal.equal?(result.current.metrics.gross_ticket_quantity, Decimal.new("2"))
    end

    test "edge semantic_version mismatch fails closed", ctx do
      PeriodComparisonHelpers.insert_edge_contribution_fact!(
        ctx.event.id,
        "ZAR",
        ctx.fragment,
        ctx.source,
        ctx.ticket_a,
        %{semantic_version: 2, gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      )

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :not_ready
    end

    test "edge coverage_identity mismatch fails closed", ctx do
      PeriodComparisonHelpers.insert_edge_contribution_fact!(
        ctx.event.id,
        "ZAR",
        ctx.fragment,
        ctx.source,
        ctx.ticket_a,
        %{
          coverage_identity: "edge_other_coverage",
          gross_ticket_quantity: 1,
          gross_ticket_value: Decimal.new("10.00")
        }
      )

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :not_ready
    end
  end

  describe "exact composition" do
    test "leading edge interior hour and trailing edge compose without gap or double count",
         ctx do
      period = %TimeRules.Period{
        start_utc: ~U[2026-05-17 10:15:00.000000Z],
        end_utc: ~U[2026-05-17 12:45:00.000000Z],
        timezone: @johannesburg,
        kind: {:comparison, :today}
      }

      %{fixed_buckets: fixed, edge_fragments: edges} =
        PeriodReadPlan.decompose_period(period, :utc_hour_interior_and_edges)

      assert length(fixed) == 1
      assert length(edges) == 2

      operand_plan = %{
        operand: :current,
        period: period,
        strategy: :utc_hour_interior_and_edges,
        fixed_buckets: Enum.map(fixed, &Map.put(&1, :operand, :current)),
        edge_fragments: Enum.map(edges, &Map.put(&1, :operand, :current))
      }

      assert_covers_operand_period!(period, operand_plan)

      for bucket <- operand_plan.fixed_buckets do
        row =
          PeriodComparisonHelpers.create_event_bucket!(
            ctx.event.id,
            "ZAR",
            bucket,
            %{gross_ticket_quantity: 10, gross_ticket_value: Decimal.new("100.00")}
          )

        PeriodComparisonHelpers.create_dimension_bucket!(
          row,
          ctx.source,
          ctx.ticket_a,
          :ticket_type
        )

        PeriodComparisonHelpers.create_dimension_bucket!(
          row,
          ctx.source,
          ctx.ticket_a,
          :source_product
        )
      end

      for fragment <- operand_plan.edge_fragments do
        PeriodComparisonHelpers.create_event_bucket!(
          ctx.event.id,
          "ZAR",
          %{
            bucket_kind: :utc_hour,
            bucket_start_utc: fragment.envelope_hour_start_utc,
            bucket_end_utc: DateTime.add(fragment.envelope_hour_start_utc, 1, :hour)
          },
          %{gross_ticket_quantity: 0, gross_ticket_value: Decimal.new("0")}
        )

        PeriodComparisonHelpers.insert_edge_contribution_fact!(
          ctx.event.id,
          "ZAR",
          fragment,
          ctx.source,
          ctx.ticket_a,
          %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
        )
      end

      {:ok, windows} = TimeRules.comparison_windows(@johannesburg, @now, :today)

      previous =
        windows.previous
        |> then(fn p ->
          %{
            operand: :previous,
            period: p,
            strategy: :utc_hour_interior_and_edges,
            fixed_buckets: [],
            edge_fragments: []
          }
        end)

      plan = %{
        windows: windows,
        operands: [operand_plan, previous],
        edge_fragment_count: length(operand_plan.edge_fragments),
        uses_edge_queries?: true
      }

      payload =
        PeriodComparisonReader.load_operand_payload_for_test!(ctx.event.id, "ZAR", plan)

      interior = hd(operand_plan.fixed_buckets)
      leading = Enum.find(operand_plan.edge_fragments, &(&1.edge_start_utc == period.start_utc))
      trailing = Enum.find(operand_plan.edge_fragments, &(&1.edge_end_utc == period.end_utc))

      assert leading
      assert trailing

      edge_keys =
        Enum.map(operand_plan.edge_fragments, fn f ->
          {f.operand, f.edge_start_utc, f.edge_end_utc}
        end)

      edge_sum =
        payload.event_edges
        |> Enum.filter(fn {key, _} -> key in edge_keys end)
        |> Enum.reduce(0, fn {_k, edge}, acc ->
          acc + Decimal.to_integer(edge.primitives.gross_ticket_quantity)
        end)

      assert edge_sum == 2

      interior_row =
        Enum.find(payload.event_rows, fn row ->
          row.bucket_start_utc == interior.bucket_start_utc and row.bucket_kind == :utc_hour
        end)

      assert interior_row.gross_ticket_quantity == 10
    end
  end

  describe "value-only refund and negative net" do
    test "value-only refund survives event and dimensional composition", ctx do
      seed_yesterday!(ctx,
        current: 0,
        previous: 0,
        current_refund_value: Decimal.new("15.00"),
        previous_refund_value: Decimal.new("0")
      )

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
                 actor: ctx.admin,
                 now: @now
               )

      assert result.current.readiness == :ready
      assert Decimal.equal?(result.current.metrics.refund_ticket_value, Decimal.new("15.00"))
      assert result.current.metrics.refund_ticket_quantity == Decimal.new("0")

      dim = hd(result.dimensions.ticket_type)

      assert Decimal.equal?(
               dim.metric_comparisons.refund_ticket_value.current,
               Decimal.new("15.00")
             )

      assert dim.metric_comparisons.refund_ticket_quantity.current == Decimal.new("0")
    end

    test "negative net is preserved and never clamped", ctx do
      seed_yesterday!(ctx,
        current: 2,
        previous: 1,
        current_refund_qty: 5,
        previous_refund_qty: 0,
        current_gross_value: Decimal.new("20.00"),
        previous_gross_value: Decimal.new("10.00"),
        current_refund_value: Decimal.new("50.00"),
        previous_refund_value: Decimal.new("0")
      )

      assert {:ok, result} =
               PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
                 actor: ctx.admin,
                 now: @now
               )

      net = result.current.metrics.net_ticket_quantity
      assert Decimal.compare(net, Decimal.new("0")) == :lt
      assert result.event.metric_comparisons.net_ticket_quantity.current == net
    end
  end

  defp seed_yesterday!(ctx, opts) do
    current = Keyword.get(opts, :current, 2)
    previous = Keyword.get(opts, :previous, 1)

    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: operand_primitives(current, opts, :current),
        previous: operand_primitives(previous, opts, :previous)
      }
    )
  end

  defp seed_yesterday_net!(ctx, opts) do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket_a,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{
          gross_ticket_quantity: 15,
          gross_ticket_value: Decimal.new("150.00"),
          refund_ticket_quantity: 10,
          refund_ticket_value: Decimal.new("100.00")
        },
        previous: %{
          gross_ticket_quantity: Keyword.get(opts, :previous_gross, 10),
          gross_ticket_value: Decimal.new("100.00"),
          refund_ticket_quantity: Keyword.get(opts, :previous_refund, 10),
          refund_ticket_value: Decimal.new("100.00")
        }
      }
    )
  end

  defp operand_primitives(gross_qty, opts, side) do
    prefix = if side == :current, do: :current, else: :previous

    %{
      gross_ticket_quantity: gross_qty,
      gross_ticket_value:
        Keyword.get(opts, :"#{prefix}_gross_value", Decimal.new("#{gross_qty * 10}.00")),
      refund_ticket_quantity: Keyword.get(opts, :"#{prefix}_refund_qty", 0),
      refund_ticket_value: Keyword.get(opts, :"#{prefix}_refund_value", Decimal.new("0"))
    }
  end

  defp seed_today_edges!(ctx, opts) do
    current_edge_qty = Keyword.get(opts, :current_edge_qty, 0)
    previous_edge_qty = Keyword.get(opts, :previous_edge_qty, 0)

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
          edge_facts: edge_fact_list(current_edge_qty)
        },
        previous: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: edge_fact_list(previous_edge_qty)
        }
      }
    )
  end

  defp edge_fact_list(0), do: %{}

  defp edge_fact_list(qty) when qty > 0 do
    %{
      default: [
        %{
          gross_ticket_quantity: qty,
          gross_ticket_value: Decimal.new("#{qty * 10}.00")
        }
      ]
    }
  end

  defp assert_state!(ctx, request, metric, expected_state) do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", request,
               actor: ctx.admin,
               now: @now
             )

    assert result.event.metric_comparisons[metric].state == expected_state
  end

  defp stale_current_bucket!(event_id) do
    row =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^event_id and currency == ^"ZAR" and projection_state == :current
      )
      |> Ash.Query.sort(bucket_start_utc: :desc)
      |> Ash.read!(domain: Analytics)
      |> hd()

    Ash.update!(row, %{projection_state: :stale}, action: :update_snapshot, domain: Analytics)
  end

  defp stale_previous_bucket!(event_id) do
    row =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^event_id and currency == ^"ZAR" and projection_state == :current
      )
      |> Ash.Query.sort(bucket_start_utc: :asc)
      |> Ash.read!(domain: Analytics)
      |> hd()

    Ash.update!(row, %{projection_state: :stale}, action: :update_snapshot, domain: Analytics)
  end

  defp set_envelope_state!(ctx, state) do
    row =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^ctx.event.id and
          currency == ^"ZAR" and
          bucket_kind == :utc_hour and
          bucket_start_utc == ^ctx.envelope_hour
      )
      |> Ash.read_one!(domain: Analytics)

    Ash.update!(row, %{projection_state: state}, action: :update_snapshot, domain: Analytics)
  end

  defp assert_covers_operand_period!(period, operand_plan) do
    intervals =
      Enum.map(operand_plan.fixed_buckets, fn b ->
        {b.bucket_start_utc, b.bucket_end_utc}
      end) ++
        Enum.map(operand_plan.edge_fragments, fn e ->
          {e.edge_start_utc, e.edge_end_utc}
        end)

    intervals =
      Enum.sort_by(intervals, fn {start, _} -> DateTime.to_unix(start, :microsecond) end)

    assert DateTime.compare(hd(intervals) |> elem(0), period.start_utc) == :eq
    assert DateTime.compare(List.last(intervals) |> elem(1), period.end_utc) == :eq

    period_us = DateTime.diff(period.end_utc, period.start_utc, :microsecond)

    covered_us =
      Enum.reduce(intervals, 0, fn {start, finish}, acc ->
        acc + DateTime.diff(finish, start, :microsecond)
      end)

    assert covered_us == period_us

    Enum.chunk_every(intervals, 2, 1, :discard)
    |> Enum.each(fn [{_s1, end_a}, {start_b, _e2}] ->
      assert DateTime.compare(end_a, start_b) == :eq
    end)
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Matrix User",
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
