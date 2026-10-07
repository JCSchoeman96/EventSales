defmodule EventSales.Analytics.PeriodCoveragePlanner do
  @moduledoc """
  Pure planner for fixed event-period bucket identities required by supported
  management comparison reads at one captured UTC instant.

  Derives coverage only from `TimeRules.comparison_windows/3` and
  `PeriodReadPlan` — no parallel period arithmetic.
  """

  alias EventSales.Analytics.{MetricRules, PeriodBucketRules, PeriodReadPlan, TimeRules}
  alias EventSales.Analytics.TimeRules.ComparisonWindows

  @supported_requests [:today, :yesterday, {:rolling_days, 7}, {:rolling_days, 30}]

  @type bucket_spec :: %{
          required(:bucket_kind) => :utc_hour | :johannesburg_day,
          required(:bucket_timezone) => String.t(),
          required(:bucket_start_utc) => DateTime.t(),
          required(:bucket_end_utc) => DateTime.t()
        }

  @doc """
  Returns the deduplicated union of canonical bucket identities required for all
  supported comparison requests at `captured_now_utc`.
  """
  @spec required_bucket_specs(DateTime.t()) :: [bucket_spec()]
  def required_bucket_specs(%DateTime{} = captured_now_utc) do
    timezone = MetricRules.business_timezone()

    base_specs =
      @supported_requests
      |> Enum.flat_map(fn request ->
        case TimeRules.comparison_windows(timezone, captured_now_utc, request) do
          {:ok, %ComparisonWindows{} = windows} ->
            case PeriodReadPlan.build(windows) do
              {:ok, plan} -> bucket_specs_from_plan(plan)
              {:error, _} -> []
            end

          {:error, _} ->
            []
        end
      end)

    johannesburg_envelopes =
      base_specs
      |> Enum.filter(&(&1.bucket_kind == :utc_hour))
      |> Enum.flat_map(&johannesburg_envelope_for_hour/1)

    (base_specs ++ johannesburg_envelopes)
    |> Enum.uniq_by(&bucket_identity_key/1)
    |> Enum.sort_by(&bucket_sort_key/1)
  end

  defp johannesburg_envelope_for_hour(%{bucket_start_utc: hour_start}) do
    case PeriodBucketRules.for_instant(hour_start) do
      {:ok, buckets} ->
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

      {:error, _} ->
        []
    end
  end

  @doc false
  @spec supported_requests() :: [:today | :yesterday | {:rolling_days, 7} | {:rolling_days, 30}]
  def supported_requests, do: @supported_requests

  defp bucket_specs_from_plan(%{operands: operands}) do
    Enum.flat_map(operands, fn operand_plan ->
      envelope_specs =
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

      fixed ++ envelope_specs
    end)
  end

  defp bucket_identity_key(spec) do
    {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
  end

  defp bucket_sort_key(spec) do
    {Atom.to_string(spec.bucket_kind), DateTime.to_unix(spec.bucket_start_utc, :microsecond)}
  end
end
