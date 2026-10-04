defmodule EventSales.Analytics.PeriodBucketRules do
  @moduledoc """
  Derives reusable fixed bucket identities for one canonical UTC instant.
  """

  alias EventSales.Analytics.TimeRules

  @johannesburg "Africa/Johannesburg"
  @utc "Etc/UTC"

  @type bucket_identity :: %{
          required(:bucket_kind) => :utc_hour | :johannesburg_day,
          required(:bucket_timezone) => String.t(),
          required(:bucket_start_utc) => DateTime.t(),
          required(:bucket_end_utc) => DateTime.t()
        }

  @doc """
  Returns the UTC-hour and Johannesburg-civil-day identities containing `instant`.

  The input must use the canonical `Etc/UTC` zone with zero UTC and standard
  offsets. Both identities represent half-open intervals.
  """
  @spec for_instant(term()) :: {:ok, [bucket_identity()]} | {:error, :invalid_utc_instant}
  def for_instant(%DateTime{} = instant) do
    if canonical_utc?(instant) do
      case johannesburg_day_period(instant) do
        {:ok, johannesburg_period} ->
          {:ok,
           [
             utc_hour_identity(instant),
             johannesburg_day_identity(johannesburg_period)
           ]}

        _error ->
          {:error, :invalid_utc_instant}
      end
    else
      {:error, :invalid_utc_instant}
    end
  end

  def for_instant(_instant), do: {:error, :invalid_utc_instant}

  defp canonical_utc?(%DateTime{
         time_zone: @utc,
         utc_offset: 0,
         std_offset: 0
       }),
       do: true

  defp canonical_utc?(_instant), do: false

  defp utc_hour_identity(%DateTime{} = instant) do
    start_utc = utc_hour_start(instant)

    %{
      bucket_kind: :utc_hour,
      bucket_timezone: "UTC",
      bucket_start_utc: start_utc,
      bucket_end_utc: DateTime.add(start_utc, 1, :hour)
    }
  end

  defp utc_hour_start(%DateTime{} = instant) do
    instant
    |> DateTime.to_naive()
    |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 6}})
    |> DateTime.from_naive!(@utc)
  end

  defp johannesburg_day_period(%DateTime{} = instant) do
    with {:ok, local} <- DateTime.shift_zone(instant, @johannesburg),
         {:ok, start_local} <- NaiveDateTime.new(DateTime.to_date(local), ~T[00:00:00.000000]),
         {:ok, end_local} <-
           NaiveDateTime.new(Date.add(DateTime.to_date(local), 1), ~T[00:00:00.000000]) do
      TimeRules.custom_civil_bounds(start_local, end_local, @johannesburg)
    end
  end

  defp johannesburg_day_identity(%TimeRules.Period{} = period) do
    %{
      bucket_kind: :johannesburg_day,
      bucket_timezone: @johannesburg,
      bucket_start_utc: period.start_utc,
      bucket_end_utc: period.end_utc
    }
  end
end
