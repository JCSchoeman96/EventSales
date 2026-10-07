defmodule EventSales.Analytics.PeriodCoveragePlannerTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.PeriodCoveragePlanner
  alias EventSales.Analytics.{PeriodReadPlan, TimeRules}

  @anchor ~U[2026-05-17 10:17:33.000000Z]

  test "required_bucket_specs unions all four supported comparison requests" do
    timezone = MetricRules.business_timezone()
    {:ok, specs} = PeriodCoveragePlanner.required_bucket_specs(@anchor)

    manual_union =
      PeriodCoveragePlanner.supported_requests()
      |> Enum.flat_map(fn request ->
        {:ok, windows} = TimeRules.comparison_windows(timezone, @anchor, request)
        {:ok, plan} = PeriodReadPlan.build(windows)
        bucket_specs_from_plan(plan)
      end)
      |> then(fn base ->
        envelopes =
          base
          |> Enum.filter(&(&1.bucket_kind == :utc_hour))
          |> Enum.flat_map(fn hour ->
            {:ok, buckets} =
              EventSales.Analytics.PeriodBucketRules.for_instant(hour.bucket_start_utc)

            buckets
            |> Enum.filter(&(&1.bucket_kind == :johannesburg_day))
            |> Enum.map(fn day ->
              %{
                bucket_kind: day.bucket_kind,
                bucket_timezone: day.bucket_timezone,
                bucket_start_utc: day.bucket_start_utc,
                bucket_end_utc: day.bucket_end_utc
              }
            end)
          end)

        base ++ envelopes
      end)
      |> Enum.uniq_by(fn spec ->
        {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
      end)

    assert length(specs) == length(manual_union)
    assert Enum.sort_by(specs, &bucket_key/1) == Enum.sort_by(manual_union, &bucket_key/1)
  end

  test "every required utc hour is enveloped by a johannesburg day spec" do
    {:ok, specs} = PeriodCoveragePlanner.required_bucket_specs(@anchor)
    hours = Enum.filter(specs, &(&1.bucket_kind == :utc_hour))
    days = Enum.filter(specs, &(&1.bucket_kind == :johannesburg_day))

    assert Enum.all?(hours, fn hour ->
             Enum.any?(days, fn day ->
               DateTime.compare(day.bucket_start_utc, hour.bucket_start_utc) in [:lt, :eq] and
                 DateTime.compare(day.bucket_end_utc, hour.bucket_end_utc) in [:gt, :eq]
             end)
           end)
  end

  test "records bounded maximum bucket cardinality for one event currency" do
    {:ok, specs} = PeriodCoveragePlanner.required_bucket_specs(@anchor)
    assert specs != []
    assert length(specs) < 2_000
    assert length(specs) == 1_502
  end

  defp bucket_specs_from_plan(%{operands: operands}) do
    Enum.flat_map(operands, fn operand_plan ->
      envelopes =
        Enum.map(operand_plan.edge_fragments, fn fragment ->
          hour_start = fragment.envelope_hour_start_utc

          %{
            bucket_kind: :utc_hour,
            bucket_timezone: "UTC",
            bucket_start_utc: hour_start,
            bucket_end_utc: DateTime.add(hour_start, 1, :hour)
          }
        end)

      fixed =
        Enum.map(operand_plan.fixed_buckets, fn bucket ->
          %{
            bucket_kind: bucket.bucket_kind,
            bucket_timezone: bucket.bucket_timezone,
            bucket_start_utc: bucket.bucket_start_utc,
            bucket_end_utc: bucket.bucket_end_utc
          }
        end)

      fixed ++ envelopes
    end)
  end

  defp bucket_key(spec) do
    {spec.bucket_kind, DateTime.to_unix(spec.bucket_start_utc, :microsecond)}
  end
end
