defmodule EventSales.Analytics.TimeRulesTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.{MetricRules, TimeRules}
  alias EventSales.Analytics.TimeRules.{Freshness, Period}
  alias EventSales.Sales.Resources.{Order, Refund}

  @johannesburg "Africa/Johannesburg"

  describe "sale_effective_at/1" do
    test "prefers paid_at when both paid and completed are present" do
      paid = ~U[2026-05-10 08:00:00.000000Z]
      completed = ~U[2026-05-12 18:00:00.000000Z]
      order = order(%{paid_at: paid, completed_at: completed})

      assert TimeRules.sale_effective_at(order) == {:ok, paid}
    end

    test "uses paid_at when only payment time is present" do
      paid = ~U[2026-05-10 08:00:00.000000Z]
      order = order(%{paid_at: paid, completed_at: nil})

      assert TimeRules.sale_effective_at(order) == {:ok, paid}
    end

    test "falls back to completed_at when paid_at is absent" do
      completed = ~U[2026-05-12 18:00:00.000000Z]
      order = order(%{paid_at: nil, completed_at: completed})

      assert TimeRules.sale_effective_at(order) == {:ok, completed}
    end

    test "returns missing error when neither clock is present" do
      order = order(%{paid_at: nil, completed_at: nil})

      assert TimeRules.sale_effective_at(order) == {:error, :missing_sale_effective_time}
    end

    test "keeps payment time when it is earlier than completion" do
      paid = ~U[2026-05-01 10:00:00.000000Z]
      completed = ~U[2026-05-05 10:00:00.000000Z]
      order = order(%{paid_at: paid, completed_at: completed})

      assert TimeRules.sale_effective_at(order) == {:ok, paid}
    end
  end

  describe "refund_effective_at/1" do
    test "uses source_created_at as authoritative refund clock" do
      source_created_at = ~U[2026-08-08 12:00:00.000000Z]
      refund = refund(%{source_created_at: source_created_at})

      assert TimeRules.refund_effective_at(refund) == {:ok, source_created_at}
    end

    test "returns missing error when source_created_at is absent" do
      refund = refund(%{source_created_at: nil})

      assert TimeRules.refund_effective_at(refund) == {:error, :missing_refund_effective_time}
    end
  end

  describe "business_date/2" do
    test "maps UTC instant to Johannesburg civil date across the UTC midnight crossover" do
      utc_boundary = ~U[2026-05-16 22:30:00.000000Z]

      assert TimeRules.business_date(utc_boundary, @johannesburg) == {:ok, ~D[2026-05-17]}
    end

    test "returns UTC civil date for UTC zone" do
      instant = ~U[2026-05-16 22:30:00.000000Z]

      assert TimeRules.business_date(instant, "UTC") == {:ok, ~D[2026-05-16]}
      assert TimeRules.business_date(instant, "Etc/UTC") == {:ok, ~D[2026-05-16]}
    end

    test "rejects invalid IANA zones" do
      instant = ~U[2026-05-16 22:30:00.000000Z]

      assert TimeRules.business_date(instant, "Invalid/Timezone") == {:error, :invalid_timezone}
    end

    test "MetricRules.business_date/2 delegates to TimeRules with the same results" do
      utc_boundary = ~U[2026-05-16 22:30:00.000000Z]

      assert MetricRules.business_date(utc_boundary, @johannesburg) ==
               TimeRules.business_date(utc_boundary, @johannesburg)
    end
  end

  describe "today_bounds/2 and yesterday_bounds/2" do
    test "today uses Johannesburg civil midnight boundaries converted once to UTC" do
      now = ~U[2026-05-17 10:00:00.000000Z]

      assert {:ok, %Period{} = period} = TimeRules.today_bounds(@johannesburg, now)

      assert period.start_utc == ~U[2026-05-16 22:00:00.000000Z]
      assert period.end_utc == ~U[2026-05-17 22:00:00.000000Z]
      assert period.kind == :today
      assert period.timezone == @johannesburg
    end

    test "today near 22:00 UTC stays on the Johannesburg civil day containing now" do
      now = ~U[2026-05-16 22:15:00.000000Z]

      assert {:ok, period} = TimeRules.today_bounds(@johannesburg, now)

      assert period.start_utc == ~U[2026-05-16 22:00:00.000000Z]
      assert period.end_utc == ~U[2026-05-17 22:00:00.000000Z]
      assert TimeRules.period_contains?(period, now)
    end

    test "yesterday is the preceding Johannesburg civil day, not a rolling 24h window" do
      now = ~U[2026-05-17 10:00:00.000000Z]

      assert {:ok, yesterday} = TimeRules.yesterday_bounds(@johannesburg, now)
      assert {:ok, today} = TimeRules.today_bounds(@johannesburg, now)

      assert yesterday.end_utc == today.start_utc
      assert yesterday.start_utc == ~U[2026-05-15 22:00:00.000000Z]
      assert yesterday.kind == :yesterday
    end
  end

  describe "rolling bounds" do
    test "last 7 days uses exact UTC duration arithmetic ending at now" do
      now = ~U[2026-06-01 12:00:00.000000Z]

      assert {:ok, period} = TimeRules.last_7_days_bounds(now)

      assert period.start_utc == ~U[2026-05-25 12:00:00.000000Z]
      assert period.end_utc == now
      assert period.kind == {:rolling_days, 7}
    end

    test "last 30 days uses exact UTC duration arithmetic" do
      now = ~U[2026-06-01 12:00:00.000000Z]

      assert {:ok, period} = TimeRules.last_30_days_bounds(now)

      assert period.start_utc == ~U[2026-05-02 12:00:00.000000Z]
      assert period.end_utc == now
    end

    test "rolling windows differ from Johannesburg calendar today bounds" do
      now = ~U[2026-05-17 10:00:00.000000Z]

      assert {:ok, rolling} = TimeRules.last_7_days_bounds(now)
      assert {:ok, today} = TimeRules.today_bounds(@johannesburg, now)

      refute rolling.start_utc == today.start_utc
      refute rolling.end_utc == today.end_utc
    end

    test "rolling bounds from a Johannesburg DateTime return Etc/UTC period fields" do
      utc_instant = ~U[2026-06-10 12:00:00.000000Z]
      {:ok, johannesburg_now} = DateTime.shift_zone(utc_instant, @johannesburg)

      assert johannesburg_now.time_zone == @johannesburg

      assert {:ok, period} = TimeRules.last_7_days_bounds(johannesburg_now)
      assert_period_etc_utc(period)
      assert DateTime.compare(period.end_utc, utc_instant) == :eq

      expected_start = DateTime.add(utc_instant, -7 * 24 * 60 * 60, :second)
      assert DateTime.compare(period.start_utc, expected_start) == :eq

      assert {:ok, rolling} = TimeRules.rolling_bounds(7, johannesburg_now)
      assert_period_etc_utc(rolling)
      assert DateTime.compare(rolling.end_utc, period.end_utc) == :eq
      assert DateTime.compare(rolling.start_utc, period.start_utc) == :eq
    end
  end

  describe "custom_civil_bounds/3" do
    test "converts Johannesburg local civil bounds to UTC half-open period" do
      start_local = ~N[2026-05-17 00:00:00]
      end_local = ~N[2026-05-18 00:00:00]

      assert {:ok, period} =
               TimeRules.custom_civil_bounds(start_local, end_local, @johannesburg)

      assert DateTime.compare(period.start_utc, ~U[2026-05-16 22:00:00.000000Z]) == :eq
      assert DateTime.compare(period.end_utc, ~U[2026-05-17 22:00:00.000000Z]) == :eq
      assert period.kind == :custom
    end

    test "rejects non-increasing local bounds" do
      start_local = ~N[2026-05-18 00:00:00]
      end_local = ~N[2026-05-17 00:00:00]

      assert TimeRules.custom_civil_bounds(start_local, end_local, @johannesburg) ==
               {:error, :invalid_period_bounds}
    end

    test "rejects equal local bounds" do
      local = ~N[2026-05-17 00:00:00]

      assert TimeRules.custom_civil_bounds(local, local, @johannesburg) ==
               {:error, :invalid_period_bounds}
    end
  end

  describe "period_contains?/2" do
    setup do
      period = %Period{
        start_utc: ~U[2026-05-01 10:00:00.000000Z],
        end_utc: ~U[2026-05-01 12:00:00.000000Z],
        kind: :custom,
        timezone: @johannesburg
      }

      [period: period]
    end

    test "includes instant exactly at start", %{period: period} do
      assert TimeRules.period_contains?(period, period.start_utc)
    end

    test "includes instant just before end", %{period: period} do
      assert TimeRules.period_contains?(period, ~U[2026-05-01 11:59:59.999999Z])
    end

    test "excludes instant exactly at end", %{period: period} do
      refute TimeRules.period_contains?(period, period.end_utc)
    end

    test "excludes instant before start", %{period: period} do
      refute TimeRules.period_contains?(period, ~U[2026-05-01 09:59:59.999999Z])
    end
  end

  describe "classify_source_freshness/2" do
    test "classifies age under five minutes as normal" do
      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 4 * 60, :second)
      now = DateTime.add(now, 59, :second)
      now = DateTime.add(now, 999_999, :microsecond)

      assert classify(anchor, now) == %Freshness{
               classification: :normal,
               age_microseconds: 299_999_999,
               clock_skew?: false
             }
    end

    test "classifies exactly five minutes as aging" do
      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 5, :minute)

      assert classify(anchor, now).classification == :aging
      assert classify(anchor, now).age_microseconds == 300_000_000
    end

    test "classifies between five and ten minutes as aging" do
      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 7, :minute)

      assert classify(anchor, now).classification == :aging
    end

    test "classifies exactly ten minutes as aging" do
      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 10, :minute)

      assert classify(anchor, now).classification == :aging
      assert classify(anchor, now).age_microseconds == 600_000_000
    end

    test "classifies ten minutes plus one millisecond as stale" do
      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 10, :minute)
      now = DateTime.add(now, 1, :millisecond)

      assert classify(anchor, now).classification == :stale
      assert classify(anchor, now).age_microseconds == 600_001_000
    end

    test "clamps future anchor to zero age and normal classification with clock skew flag" do
      now = ~U[2026-05-01 10:00:00.000000Z]
      anchor = DateTime.add(now, 30, :second)

      assert classify(anchor, now) == %Freshness{
               classification: :normal,
               age_microseconds: 0,
               clock_skew?: true
             }
    end
  end

  defp classify(anchor, now), do: TimeRules.classify_source_freshness(anchor, now)

  defp assert_period_etc_utc(%Period{start_utc: start_utc, end_utc: end_utc}) do
    for field <- [start_utc, end_utc] do
      assert field.time_zone == "Etc/UTC"
      assert field.utc_offset == 0
      assert field.std_offset == 0
    end
  end

  defp order(attrs) do
    struct!(
      Order,
      Map.merge(
        %{
          status: :completed,
          paid_at: nil,
          completed_at: nil
        },
        attrs
      )
    )
  end

  defp refund(attrs) do
    struct!(
      Refund,
      Map.merge(
        %{
          source_state: :active,
          detail_status: :complete
        },
        attrs
      )
    )
  end
end
