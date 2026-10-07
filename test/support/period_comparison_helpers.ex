defmodule EventSales.TestSupport.PeriodComparisonHelpers do
  @moduledoc false

  alias EventSales.Analytics
  alias EventSales.Analytics.{MetricRules, PeriodReadPlan, TimeRules}

  alias EventSales.Analytics.Resources.{
    EventDimensionPeriodAggregateSnapshot,
    EventPeriodAggregateSnapshot
  }

  @coverage "m5_04_period_comparison_v1"
  @refreshed_at ~U[2026-07-10 10:00:00.000000Z]

  @doc false
  def default_coverage_identity, do: @coverage

  @doc false
  def default_refreshed_at, do: @refreshed_at

  @doc false
  def create_event_bucket!(event_id, currency, spec, overrides \\ %{}) do
    primitives =
      default_primitives()
      |> Map.merge(Map.take(overrides, Map.keys(default_primitives())))

    generation_id = Map.get(overrides, :generation_id, Ecto.UUID.generate())
    projection_state = Map.get(overrides, :projection_state, :current)
    semantic_version = Map.get(overrides, :semantic_version, 1)
    coverage_identity = Map.get(overrides, :coverage_identity, @coverage)

    Ash.create!(
      EventPeriodAggregateSnapshot,
      %{
        event_id: event_id,
        currency: currency,
        bucket_kind: spec.bucket_kind,
        bucket_timezone: Map.get(spec, :bucket_timezone, bucket_timezone(spec.bucket_kind)),
        bucket_start_utc: spec.bucket_start_utc,
        bucket_end_utc: spec.bucket_end_utc,
        gross_ticket_quantity: primitives.gross_ticket_quantity,
        gross_ticket_value: primitives.gross_ticket_value,
        refund_ticket_quantity: primitives.refund_ticket_quantity,
        refund_ticket_value: primitives.refund_ticket_value,
        generation_id: generation_id,
        semantic_version: semantic_version,
        coverage_identity: coverage_identity,
        projection_state: projection_state,
        refreshed_at: @refreshed_at,
        source_watermark_at: nil
      },
      action: :create_snapshot,
      domain: Analytics
    )
  end

  @doc false
  def create_dimension_bucket!(event_row, source, ticket, dimension_kind, overrides \\ %{}) do
    base = %{
      event_id: event_row.event_id,
      currency: event_row.currency,
      bucket_kind: event_row.bucket_kind,
      bucket_timezone: event_row.bucket_timezone,
      bucket_start_utc: event_row.bucket_start_utc,
      bucket_end_utc: event_row.bucket_end_utc,
      gross_ticket_quantity: event_row.gross_ticket_quantity,
      gross_ticket_value: event_row.gross_ticket_value,
      refund_ticket_quantity: event_row.refund_ticket_quantity,
      refund_ticket_value: event_row.refund_ticket_value,
      generation_id: event_row.generation_id,
      semantic_version: event_row.semantic_version,
      coverage_identity: event_row.coverage_identity,
      projection_state: event_row.projection_state,
      refreshed_at: event_row.refreshed_at,
      source_watermark_at: event_row.source_watermark_at
    }

    extra =
      case dimension_kind do
        :ticket_type ->
          %{dimension_kind: :ticket_type, ticket_type_id: ticket.id}

        :source_product ->
          %{
            dimension_kind: :source_product,
            source_system_id: source.id,
            woo_product_id: 81_001,
            ticket_type_id: nil
          }

        :source_variation ->
          %{
            dimension_kind: :source_variation,
            source_system_id: source.id,
            woo_product_id: 81_001,
            woo_variation_id: 81_002,
            ticket_type_id: nil
          }
      end

    Ash.create!(
      EventDimensionPeriodAggregateSnapshot,
      Map.merge(Map.merge(base, extra), overrides),
      action: :create_snapshot,
      domain: Analytics
    )
  end

  @doc false
  def insert_edge_contribution_fact!(event_id, currency, fragment, source, ticket, attrs \\ %{}) do
    insert_contribution_fact!(
      event_id,
      currency,
      Map.get(attrs, :generation_id, Ecto.UUID.generate()),
      fragment,
      attrs,
      source,
      ticket
    )
  end

  def plan_for(request, now) do
    timezone = MetricRules.business_timezone()

    with {:ok, windows} <- TimeRules.comparison_windows(timezone, now, request),
         {:ok, plan} <- PeriodReadPlan.build(windows) do
      {:ok, windows, plan}
    end
  end

  def seed_comparison_projection!(event, source, ticket, currency, request, now, operand_attrs) do
    {:ok, _windows, plan} = plan_for(request, now)
    generation_id = Ecto.UUID.generate()

    for operand_plan <- plan.operands do
      attrs = Map.fetch!(operand_attrs, operand_plan.operand)
      seed_operand!(event, source, ticket, currency, operand_plan, generation_id, attrs)
    end

    :ok
  end

  @doc false
  def seed_asymmetric_comparison_projection!(
        event,
        source,
        previous_ticket,
        current_ticket,
        currency,
        request,
        now,
        operand_attrs
      ) do
    {:ok, _windows, plan} = plan_for(request, now)
    generation_id = Ecto.UUID.generate()

    for operand_plan <- plan.operands do
      {ticket, attrs} =
        case operand_plan.operand do
          :previous -> {previous_ticket, Map.fetch!(operand_attrs, :previous)}
          :current -> {current_ticket, Map.fetch!(operand_attrs, :current)}
        end

      seed_operand!(event, source, ticket, currency, operand_plan, generation_id, attrs)
    end

    :ok
  end

  defp seed_operand!(event, source, ticket, currency, operand_plan, generation_id, attrs) do
    primitives = Map.merge(default_primitives(), Map.take(attrs, Map.keys(default_primitives())))

    fixed_buckets = operand_plan.fixed_buckets

    envelope_specs =
      operand_plan.edge_fragments
      |> Enum.map(fn fragment ->
        hour_start = fragment.envelope_hour_start_utc

        %{
          bucket_kind: :utc_hour,
          bucket_start_utc: hour_start,
          bucket_end_utc: DateTime.add(hour_start, 1, :hour)
        }
      end)

    specs =
      (fixed_buckets ++ envelope_specs)
      |> Enum.uniq_by(fn spec ->
        {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
      end)

    fixed_keys =
      fixed_buckets
      |> Enum.map(fn b -> {b.bucket_kind, b.bucket_start_utc, b.bucket_end_utc} end)
      |> MapSet.new()

    Enum.each(specs, fn spec ->
      event_row =
        create_event_bucket!(
          event.id,
          currency,
          spec,
          generation_id,
          primitives
        )

      key = {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}

      if MapSet.member?(fixed_keys, key) and not zero_primitives?(primitives) do
        seed_required_dimensions!(event_row, source, ticket, primitives)
      end
    end)

    Enum.each(operand_plan.edge_fragments, fn fragment ->
      facts =
        attrs
        |> Map.get(:edge_facts, %{})
        |> Map.get(edge_key(fragment), Map.get(attrs[:edge_facts] || %{}, :default, []))

      Enum.each(facts, fn fact_attrs ->
        insert_contribution_fact!(
          event.id,
          currency,
          generation_id,
          fragment,
          fact_attrs,
          source,
          ticket
        )
      end)
    end)
  end

  defp default_primitives do
    %{
      gross_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_quantity: 0,
      refund_ticket_value: Decimal.new("0")
    }
  end

  defp zero_primitives?(primitives) do
    primitives.gross_ticket_quantity == 0 and primitives.refund_ticket_quantity == 0 and
      Decimal.equal?(primitives.gross_ticket_value, Decimal.new("0")) and
      Decimal.equal?(primitives.refund_ticket_value, Decimal.new("0"))
  end

  defp create_event_bucket!(event_id, currency, spec, generation_id, primitives) do
    create_event_bucket!(
      event_id,
      currency,
      spec,
      Map.merge(primitives, %{generation_id: generation_id})
    )
  end

  defp seed_required_dimensions!(event_row, source, ticket, primitives) do
    base = %{
      event_id: event_row.event_id,
      currency: event_row.currency,
      bucket_kind: event_row.bucket_kind,
      bucket_timezone: event_row.bucket_timezone,
      bucket_start_utc: event_row.bucket_start_utc,
      bucket_end_utc: event_row.bucket_end_utc,
      gross_ticket_quantity: primitives.gross_ticket_quantity,
      gross_ticket_value: primitives.gross_ticket_value,
      refund_ticket_quantity: primitives.refund_ticket_quantity,
      refund_ticket_value: primitives.refund_ticket_value,
      generation_id: event_row.generation_id,
      semantic_version: event_row.semantic_version,
      coverage_identity: event_row.coverage_identity,
      projection_state: :current,
      refreshed_at: event_row.refreshed_at,
      source_watermark_at: event_row.source_watermark_at
    }

    for {_kind, extra} <- [
          {:ticket_type, %{dimension_kind: :ticket_type, ticket_type_id: ticket.id}},
          {:source_product,
           %{
             dimension_kind: :source_product,
             source_system_id: source.id,
             woo_product_id: 81_001,
             ticket_type_id: nil
           }},
          {:source_variation,
           %{
             dimension_kind: :source_variation,
             source_system_id: source.id,
             woo_product_id: 81_001,
             woo_variation_id: 81_002,
             ticket_type_id: nil
           }}
        ] do
      Ash.create!(
        EventDimensionPeriodAggregateSnapshot,
        Map.merge(base, extra),
        action: :create_snapshot,
        domain: Analytics
      )
    end
  end

  defp insert_contribution_fact!(
         event_id,
         currency,
         generation_id,
         fragment,
         fact_attrs,
         source,
         ticket
       ) do
    defaults = %{
      contribution_kind: :sale,
      source_contribution_id: Ecto.UUID.generate(),
      event_id: event_id,
      currency: currency,
      effective_at: DateTime.add(fragment.edge_start_utc, 30, :second),
      ticket_type_id: ticket.id,
      source_system_id: source.id,
      woo_product_id: 81_001,
      woo_variation_id: 81_002,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refund_ticket_quantity: 0,
      refund_ticket_value: Decimal.new("0"),
      generation_id: generation_id,
      semantic_version: 1,
      coverage_identity: @coverage,
      refreshed_at: @refreshed_at,
      source_watermark_at: nil
    }

    attrs = Map.merge(defaults, fact_attrs)

    Ash.create!(EventSales.Analytics.Resources.AnalyticsContributionFact, attrs,
      action: :create_fact,
      domain: Analytics
    )
  end

  defp bucket_timezone(:utc_hour), do: "UTC"
  defp bucket_timezone(:johannesburg_day), do: MetricRules.business_timezone()

  defp edge_key(fragment), do: {fragment.edge_start_utc, fragment.edge_end_utc}
end
