defmodule EventSales.Analytics.ProjectionPeriodReaderTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.{
    EventSnapshotRefreshFence,
    PeriodReadPlan,
    ProjectionPeriodReader,
    TimeRules
  }

  alias EventSales.Repo
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 11:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Projection reader"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    %{source: source, event: event, ticket: ticket}
  end

  test "read composes ready operands from fixed projection buckets", ctx do
    {:ok, windows} = TimeRules.velocity_windows(@now, {:rolling_minutes, 60})
    {:ok, plan} = PeriodReadPlan.build(windows)

    assert plan.edge_fragment_count == 0

    expected = %{
      current: %{
        gross_ticket_quantity: Decimal.new("12"),
        refund_ticket_quantity: Decimal.new("2"),
        gross_ticket_value: Decimal.new("120.25"),
        refund_ticket_value: Decimal.new("20.00")
      },
      previous: %{
        gross_ticket_quantity: Decimal.new("5"),
        refund_ticket_quantity: Decimal.new("1"),
        gross_ticket_value: Decimal.new("50.50"),
        refund_ticket_value: Decimal.new("5.25")
      }
    }

    Enum.each(plan.operands, fn operand_plan ->
      [bucket] = operand_plan.fixed_buckets
      primitives = Map.fetch!(expected, operand_plan.operand)

      seed_values =
        Map.merge(primitives, %{
          gross_ticket_quantity: Decimal.to_integer(primitives.gross_ticket_quantity),
          refund_ticket_quantity: Decimal.to_integer(primitives.refund_ticket_quantity)
        })

      PeriodComparisonHelpers.create_event_bucket!(ctx.event.id, "ZAR", bucket, seed_values)
    end)

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert length(projection.event_rows) == 2

    for operand <- [:current, :previous] do
      result = projection_operand(projection, operand)
      assert result.readiness == :ready

      assert result.scope == %{
               semantic_version: 1,
               coverage_identity: PeriodComparisonHelpers.default_coverage_identity()
             }

      assert result.primitives == Map.fetch!(expected, operand)
    end
  end

  test "read adds only bounded event contribution edges to each operand", ctx do
    {:ok, windows} =
      TimeRules.velocity_windows(~U[2026-05-17 10:30:00.000000Z], {:rolling_minutes, 60})

    {:ok, plan} = PeriodReadPlan.build(windows)

    assert plan.edge_fragment_count == 4
    seed_event_buckets!(ctx.event.id, "ZAR", plan)

    Enum.each(plan.operands, fn operand_plan ->
      Enum.each(operand_plan.edge_fragments, fn fragment ->
        PeriodComparisonHelpers.insert_edge_contribution_fact!(
          ctx.event.id,
          "ZAR",
          fragment,
          ctx.source,
          ctx.ticket,
          %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
        )
      end)
    end)

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    for operand <- [:current, :previous] do
      result = projection_operand(projection, operand)
      assert result.readiness == :ready

      assert Decimal.equal?(
               result.primitives.gross_ticket_quantity,
               Decimal.new("2")
             )

      assert Decimal.equal?(
               result.primitives.gross_ticket_value,
               Decimal.new("20.00")
             )
    end
  end

  test "edge facts respect event, currency, and half-open time bounds", ctx do
    {:ok, windows} =
      TimeRules.velocity_windows(~U[2026-05-17 10:30:00.000000Z], {:rolling_minutes, 60})

    {:ok, plan} = PeriodReadPlan.build(windows)
    seed_event_buckets!(ctx.event.id, "ZAR", plan)

    current = Enum.find(plan.operands, &(&1.operand == :current))
    edge = List.last(current.edge_fragments)

    insert_fact!(ctx.event.id, "ZAR", edge, ctx.source, ctx.ticket, %{
      effective_at: edge.edge_start_utc,
      gross_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("20.00")
    })

    insert_fact!(ctx.event.id, "USD", edge, ctx.source, ctx.ticket, %{
      effective_at: DateTime.add(edge.edge_start_utc, 1, :second),
      gross_ticket_quantity: 50,
      gross_ticket_value: Decimal.new("500.00")
    })

    other_source = SalesHelpers.create_source_system!()
    other_event = SalesHelpers.create_event!(other_source, %{name: "Other projection event"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other GA"})

    insert_fact!(other_event.id, "ZAR", edge, other_source, other_ticket, %{
      effective_at: DateTime.add(edge.edge_start_utc, 1, :second),
      gross_ticket_quantity: 60,
      gross_ticket_value: Decimal.new("600.00")
    })

    insert_fact!(ctx.event.id, "ZAR", edge, ctx.source, ctx.ticket, %{
      effective_at: edge.edge_end_utc,
      gross_ticket_quantity: 70,
      gross_ticket_value: Decimal.new("700.00")
    })

    insert_fact!(ctx.event.id, "ZAR", edge, ctx.source, ctx.ticket, %{
      effective_at: DateTime.add(windows.current.start_utc, -1, :second),
      gross_ticket_quantity: 80,
      gross_ticket_value: Decimal.new("800.00")
    })

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand.readiness == :ready

    assert Decimal.equal?(
             projection.current_operand.primitives.gross_ticket_quantity,
             Decimal.new("2")
           )

    assert Decimal.equal?(
             projection.current_operand.primitives.gross_ticket_value,
             Decimal.new("20.00")
           )
  end

  test "missing required event coverage fails closed instead of becoming zero", ctx do
    {:ok, windows} = TimeRules.velocity_windows(@now, {:rolling_minutes, 60})
    {:ok, plan} = PeriodReadPlan.build(windows)
    [current_bucket] = Enum.find(plan.operands, &(&1.operand == :current)).fixed_buckets
    seed_event_buckets!(ctx.event.id, "ZAR", plan, exclude: [current_bucket])

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand == %{readiness: :not_ready, scope: nil, primitives: nil}
  end

  test "an explicit compatible zero bucket is ready zero", ctx do
    {:ok, windows} = TimeRules.velocity_windows(@now, {:rolling_minutes, 60})
    {:ok, plan} = PeriodReadPlan.build(windows)
    seed_event_buckets!(ctx.event.id, "ZAR", plan)

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand.readiness == :ready

    assert projection.current_operand.scope.coverage_identity ==
             PeriodComparisonHelpers.default_coverage_identity()

    assert projection.current_operand.primitives == %{
             gross_ticket_quantity: Decimal.new(0),
             refund_ticket_quantity: Decimal.new(0),
             gross_ticket_value: Decimal.new(0),
             refund_ticket_value: Decimal.new(0)
           }
  end

  test "a stale required event bucket fails closed", ctx do
    {:ok, windows} = TimeRules.velocity_windows(@now, {:rolling_minutes, 60})
    {:ok, plan} = PeriodReadPlan.build(windows)
    [current_bucket] = Enum.find(plan.operands, &(&1.operand == :current)).fixed_buckets

    seed_event_buckets!(ctx.event.id, "ZAR", plan,
      overrides: %{key(current_bucket) => %{projection_state: :stale}}
    )

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand == %{readiness: :not_ready, scope: nil, primitives: nil}
  end

  test "event buckets with incoherent scope metadata fail closed", ctx do
    {:ok, windows} =
      TimeRules.velocity_windows(~U[2026-05-17 10:30:00.000000Z], {:rolling_minutes, 60})

    {:ok, plan} = PeriodReadPlan.build(windows)
    current = Enum.find(plan.operands, &(&1.operand == :current))
    [changed_edge | _] = current.edge_fragments
    hour_start = changed_edge.envelope_hour_start_utc

    changed_bucket = %{
      bucket_kind: :utc_hour,
      bucket_start_utc: hour_start,
      bucket_end_utc: DateTime.add(hour_start, 1, :hour)
    }

    seed_event_buckets!(ctx.event.id, "ZAR", plan,
      overrides: %{key(changed_bucket) => %{semantic_version: 2}}
    )

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand == %{readiness: :not_ready, scope: nil, primitives: nil}
  end

  test "event buckets with different coverage identities fail closed", ctx do
    {:ok, windows} =
      TimeRules.velocity_windows(~U[2026-05-17 10:30:00.000000Z], {:rolling_minutes, 60})

    {:ok, plan} = PeriodReadPlan.build(windows)
    current = Enum.find(plan.operands, &(&1.operand == :current))
    [changed_edge | _] = current.edge_fragments
    hour_start = changed_edge.envelope_hour_start_utc

    changed_bucket = %{
      bucket_kind: :utc_hour,
      bucket_start_utc: hour_start,
      bucket_end_utc: DateTime.add(hour_start, 1, :hour)
    }

    seed_event_buckets!(ctx.event.id, "ZAR", plan,
      overrides: %{key(changed_bucket) => %{coverage_identity: "different-coverage"}}
    )

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand == %{readiness: :not_ready, scope: nil, primitives: nil}
  end

  test "edge facts with incompatible scope metadata fail closed", ctx do
    {:ok, windows} =
      TimeRules.velocity_windows(~U[2026-05-17 10:30:00.000000Z], {:rolling_minutes, 60})

    {:ok, plan} = PeriodReadPlan.build(windows)
    seed_event_buckets!(ctx.event.id, "ZAR", plan)
    current = Enum.find(plan.operands, &(&1.operand == :current))
    [semantic_edge, coverage_edge | _] = current.edge_fragments

    insert_fact!(ctx.event.id, "ZAR", semantic_edge, ctx.source, ctx.ticket, %{
      semantic_version: 2,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00")
    })

    insert_fact!(ctx.event.id, "ZAR", coverage_edge, ctx.source, ctx.ticket, %{
      coverage_identity: "different-coverage",
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00")
    })

    projection = read_in_coherent_transaction!(ctx.event.id, "ZAR", plan)

    assert projection.current_operand == %{readiness: :not_ready, scope: nil, primitives: nil}
  end

  defp read_in_coherent_transaction!(event_id, currency, plan) do
    assert {:ok, {:ok, projection}} =
             Repo.transaction(fn ->
               :ok = EventSnapshotRefreshFence.prepare_coherent_transaction!()
               ProjectionPeriodReader.read(event_id, currency, plan)
             end)

    projection
  end

  defp projection_operand(projection, :current), do: projection.current_operand
  defp projection_operand(projection, :previous), do: projection.previous_operand

  defp insert_fact!(event_id, currency, fragment, source, ticket, attrs) do
    PeriodComparisonHelpers.insert_edge_contribution_fact!(
      event_id,
      currency,
      fragment,
      source,
      ticket,
      attrs
    )
  end

  defp seed_event_buckets!(event_id, currency, plan, opts \\ []) do
    excluded = Keyword.get(opts, :exclude, []) |> Enum.map(&key/1)
    overrides = Keyword.get(opts, :overrides, %{})

    plan.operands
    |> Enum.flat_map(fn operand ->
      envelope_specs =
        Enum.map(operand.edge_fragments, fn fragment ->
          hour_start = fragment.envelope_hour_start_utc

          %{
            bucket_kind: :utc_hour,
            bucket_start_utc: hour_start,
            bucket_end_utc: DateTime.add(hour_start, 1, :hour)
          }
        end)

      operand.fixed_buckets ++ envelope_specs
    end)
    |> Enum.uniq_by(fn spec ->
      {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
    end)
    |> Enum.each(fn spec ->
      unless key(spec) in excluded do
        PeriodComparisonHelpers.create_event_bucket!(
          event_id,
          currency,
          spec,
          Map.get(overrides, key(spec), %{})
        )
      end
    end)
  end

  defp key(spec), do: {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
end
