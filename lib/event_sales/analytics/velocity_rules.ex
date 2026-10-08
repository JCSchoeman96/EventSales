defmodule EventSales.Analytics.VelocityRules do
  @moduledoc """
  Pure sales-velocity rate normalization and trend comparison helpers.

  No database, cache, process state, or system clock access.
  """

  alias EventSales.Analytics.MetricRules

  @seconds_per_hour 3600
  @zero Decimal.new(0)

  @type rate_comparison :: %{
          absolute_delta: Decimal.t() | nil,
          percentage_delta: Decimal.t() | nil,
          direction: :faster | :flat | :slower
        }

  @doc """
  Normalizes a raw window total to an hourly rate using exact `Decimal` arithmetic.

  Rejects non-positive `window_duration_seconds` to avoid division by zero.
  """
  @spec rate_per_hour(Decimal.t(), integer()) ::
          {:ok, Decimal.t()} | {:error, :invalid_window_duration}
  def rate_per_hour(%Decimal{} = raw_value, window_duration_seconds)
      when is_integer(window_duration_seconds) and window_duration_seconds > 0 do
    factor = Decimal.div(Decimal.new(@seconds_per_hour), Decimal.new(window_duration_seconds))
    {:ok, Decimal.mult(raw_value, factor)}
  end

  def rate_per_hour(%Decimal{} = _raw_value, _window_duration_seconds),
    do: {:error, :invalid_window_duration}

  @doc """
  Compares two normalized rates using M5-04 delta semantics and exact-sign direction.
  """
  @spec compare_rates(Decimal.t(), Decimal.t()) :: rate_comparison()
  def compare_rates(%Decimal{} = current_rate, %Decimal{} = previous_rate) do
    state =
      MetricRules.classify_comparison_state(%{
        current_readiness: :ready,
        comparison_readiness: :ready,
        comparable: true,
        comparison_grain_zero_activity: false,
        current_metric: current_rate,
        comparison_metric: previous_rate
      })

    deltas = MetricRules.derive_comparison_deltas(state, current_rate, previous_rate)

    Map.put(deltas, :direction, direction(current_rate, previous_rate))
  end

  defp direction(%Decimal{} = current_rate, %Decimal{} = previous_rate) do
    case Decimal.compare(Decimal.sub(current_rate, previous_rate), @zero) do
      :gt -> :faster
      :eq -> :flat
      :lt -> :slower
    end
  end
end
