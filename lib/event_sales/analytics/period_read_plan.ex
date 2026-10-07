defmodule EventSales.Analytics.PeriodReadPlan do
  @moduledoc """
  Derives fixed-bucket and bounded contribution-edge fragments for one comparison read.

  Rolling and elapsed-day operands decompose into fully enclosed UTC-hour interiors
  plus optional leading/trailing sub-hour edges. Yesterday operands use one
  Johannesburg civil-day bucket each with no contribution edge queries.
  """

  alias EventSales.Analytics.TimeRules.ComparisonWindows
  alias EventSales.Analytics.TimeRules.Period

  @utc "Etc/UTC"
  @max_edge_fragments 4

  @type operand :: :current | :previous

  @type edge_fragment :: %{
          operand: operand(),
          edge_start_utc: DateTime.t(),
          edge_end_utc: DateTime.t(),
          envelope_hour_start_utc: DateTime.t()
        }

  @type fixed_bucket :: %{
          operand: operand(),
          bucket_kind: :utc_hour | :johannesburg_day,
          bucket_timezone: String.t(),
          bucket_start_utc: DateTime.t(),
          bucket_end_utc: DateTime.t()
        }

  @type operand_plan :: %{
          operand: operand(),
          period: Period.t(),
          strategy: :johannesburg_day | :utc_hour_interior_and_edges,
          fixed_buckets: [fixed_bucket()],
          edge_fragments: [edge_fragment()]
        }

  @type t :: %{
          windows: ComparisonWindows.t(),
          operands: [operand_plan()],
          edge_fragment_count: non_neg_integer(),
          uses_edge_queries?: boolean()
        }

  @doc """
  Builds the read plan for one `TimeRules.comparison_windows/3` result.
  """
  @spec build(ComparisonWindows.t()) :: {:ok, t()} | {:error, :too_many_edge_fragments}
  def build(%ComparisonWindows{} = windows) do
    strategy = operand_strategy(windows.request)

    operands =
      [
        operand_plan(:current, windows.current, strategy),
        operand_plan(:previous, windows.previous, strategy)
      ]

    edge_fragments =
      operands
      |> Enum.flat_map(& &1.edge_fragments)

    if length(edge_fragments) > @max_edge_fragments do
      {:error, :too_many_edge_fragments}
    else
      {:ok,
       %{
         windows: windows,
         operands: operands,
         edge_fragment_count: length(edge_fragments),
         uses_edge_queries?: edge_fragments != []
       }}
    end
  end

  @doc """
  Decomposes one half-open UTC period into fixed interiors and edge fragments.

  Exposed for focused unit tests.
  """
  @spec decompose_period(Period.t(), :johannesburg_day | :utc_hour_interior_and_edges) ::
          %{fixed_buckets: [fixed_bucket()], edge_fragments: [edge_fragment()]}
  def decompose_period(%Period{} = period, strategy) do
    case strategy do
      :johannesburg_day ->
        %{
          fixed_buckets: [johannesburg_day_bucket(period)],
          edge_fragments: []
        }

      :utc_hour_interior_and_edges ->
        decompose_utc_hour_period(period)
    end
  end

  defp operand_strategy(:yesterday), do: :johannesburg_day
  defp operand_strategy(_request), do: :utc_hour_interior_and_edges

  defp operand_plan(operand, period, strategy) do
    %{fixed_buckets: fixed, edge_fragments: edges} = decompose_period(period, strategy)

    %{
      operand: operand,
      period: period,
      strategy: strategy,
      fixed_buckets: Enum.map(fixed, &Map.put(&1, :operand, operand)),
      edge_fragments: Enum.map(edges, &Map.put(&1, :operand, operand))
    }
  end

  defp johannesburg_day_bucket(%Period{start_utc: start, end_utc: end_utc, timezone: tz}) do
    %{
      operand: nil,
      bucket_kind: :johannesburg_day,
      bucket_timezone: tz || "Africa/Johannesburg",
      bucket_start_utc: start,
      bucket_end_utc: end_utc
    }
  end

  defp decompose_utc_hour_period(%Period{start_utc: start, end_utc: end_utc}) do
    cond do
      DateTime.compare(start, end_utc) != :lt ->
        %{fixed_buckets: [], edge_fragments: []}

      full_utc_hour_bucket?(start, end_utc) ->
        %{
          fixed_buckets: [
            %{
              operand: nil,
              bucket_kind: :utc_hour,
              bucket_timezone: "UTC",
              bucket_start_utc: start,
              bucket_end_utc: end_utc
            }
          ],
          edge_fragments: []
        }

      sub_hour_only_window?(start, end_utc) ->
        hour_start = utc_hour_start(start)

        %{
          fixed_buckets: [],
          edge_fragments: [
            %{
              operand: nil,
              edge_start_utc: start,
              edge_end_utc: end_utc,
              envelope_hour_start_utc: hour_start
            }
          ]
        }

      true ->
        first_interior = first_interior_hour_start(start)
        last_interior = last_interior_hour_start(end_utc)

        leading =
          if DateTime.compare(start, first_interior) == :lt do
            [
              %{
                operand: nil,
                edge_start_utc: start,
                edge_end_utc: first_interior,
                envelope_hour_start_utc: utc_hour_start(start)
              }
            ]
          else
            []
          end

        trailing_start = trailing_edge_start(end_utc)

        trailing =
          if DateTime.compare(trailing_start, end_utc) == :lt do
            [
              %{
                operand: nil,
                edge_start_utc: trailing_start,
                edge_end_utc: end_utc,
                envelope_hour_start_utc: utc_hour_start(trailing_start)
              }
            ]
          else
            []
          end

        interiors =
          if DateTime.compare(first_interior, last_interior) == :gt do
            []
          else
            enumerate_interior_hours(first_interior, last_interior)
          end

        %{
          fixed_buckets: interiors,
          edge_fragments: leading ++ trailing
        }
    end
  end

  defp enumerate_interior_hours(first, last) do
    Stream.unfold(first, fn hour_start ->
      if DateTime.compare(hour_start, last) == :gt do
        nil
      else
        next = DateTime.add(hour_start, 1, :hour)

        {%{
           operand: nil,
           bucket_kind: :utc_hour,
           bucket_timezone: "UTC",
           bucket_start_utc: hour_start,
           bucket_end_utc: next
         }, next}
      end
    end)
    |> Enum.to_list()
  end

  defp full_utc_hour_bucket?(start, end_exclusive) do
    hour_start = utc_hour_start(start)

    DateTime.compare(start, hour_start) == :eq and
      DateTime.compare(end_exclusive, DateTime.add(hour_start, 1, :hour)) == :eq
  end

  defp sub_hour_only_window?(start, end_exclusive) do
    hour_start = utc_hour_start(start)
    hour_end = DateTime.add(hour_start, 1, :hour)

    DateTime.compare(end_exclusive, hour_end) != :gt and
      not full_utc_hour_bucket?(start, end_exclusive)
  end

  defp first_interior_hour_start(%DateTime{} = start) do
    hour_start = utc_hour_start(start)

    if DateTime.compare(start, hour_start) == :eq do
      hour_start
    else
      DateTime.add(hour_start, 1, :hour)
    end
  end

  defp last_interior_hour_start(%DateTime{} = end_exclusive) do
    DateTime.add(utc_hour_start(end_exclusive), -1, :hour)
  end

  defp trailing_edge_start(%DateTime{} = end_exclusive) do
    hour_start = utc_hour_start(end_exclusive)

    if DateTime.compare(end_exclusive, hour_start) == :eq do
      hour_start
    else
      hour_start
    end
  end

  defp utc_hour_start(%DateTime{} = instant) do
    instant
    |> DateTime.to_naive()
    |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 6}})
    |> DateTime.from_naive!(@utc)
  end
end
