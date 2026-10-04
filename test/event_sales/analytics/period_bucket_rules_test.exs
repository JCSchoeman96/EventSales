defmodule EventSales.Analytics.PeriodBucketRulesTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.PeriodBucketRules

  @johannesburg "Africa/Johannesburg"

  describe "for_instant/1" do
    test "returns exact UTC hour and Johannesburg civil day identities" do
      instant = ~U[2026-05-17 10:34:56.789012Z]

      assert {:ok, [utc_hour, johannesburg_day]} = PeriodBucketRules.for_instant(instant)

      assert utc_hour == %{
               bucket_kind: :utc_hour,
               bucket_timezone: "UTC",
               bucket_start_utc: ~U[2026-05-17 10:00:00.000000Z],
               bucket_end_utc: ~U[2026-05-17 11:00:00.000000Z]
             }

      assert johannesburg_day == %{
               bucket_kind: :johannesburg_day,
               bucket_timezone: @johannesburg,
               bucket_start_utc: ~U[2026-05-16 22:00:00.000000Z],
               bucket_end_utc: ~U[2026-05-17 22:00:00.000000Z]
             }
    end

    test "instants in the same fixed intervals return the same identities" do
      first_instant = ~U[2026-06-01 12:34:56.000000Z]
      last_instant = ~U[2026-06-01 12:59:59.999999Z]

      assert {:ok, buckets} = PeriodBucketRules.for_instant(first_instant)
      assert PeriodBucketRules.for_instant(last_instant) == {:ok, buckets}
    end

    test "uses half-open boundaries for both bucket kinds" do
      hour_before = ~U[2026-05-17 09:59:59.999999Z]
      hour_start = ~U[2026-05-17 10:00:00.000000Z]

      assert {:ok, [previous_hour, _previous_day]} = PeriodBucketRules.for_instant(hour_before)
      assert {:ok, [next_hour, _current_day]} = PeriodBucketRules.for_instant(hour_start)

      assert previous_hour.bucket_end_utc == hour_start
      assert next_hour.bucket_start_utc == hour_start

      day_before = ~U[2026-05-17 21:59:59.999999Z]
      day_start = ~U[2026-05-17 22:00:00.000000Z]

      assert {:ok, [_previous_hour, previous_day]} = PeriodBucketRules.for_instant(day_before)
      assert {:ok, [_next_hour, next_day]} = PeriodBucketRules.for_instant(day_start)

      assert previous_day.bucket_end_utc == day_start
      assert next_day.bucket_start_utc == day_start
    end

    test "preserves microsecond precision while deriving boundaries" do
      instant = ~U[2026-06-01 12:34:56.789012Z]

      assert instant.microsecond == {789_012, 6}
      assert {:ok, [utc_hour, johannesburg_day]} = PeriodBucketRules.for_instant(instant)

      assert utc_hour.bucket_start_utc.microsecond == {0, 6}
      assert utc_hour.bucket_end_utc.microsecond == {0, 6}
      assert johannesburg_day.bucket_start_utc.microsecond == {0, 6}
      assert johannesburg_day.bucket_end_utc.microsecond == {0, 6}
    end

    test "rejects non-UTC and invalid instants" do
      {:ok, non_utc} = DateTime.from_naive(~N[2026-05-17 10:34:56.789012], @johannesburg)

      assert PeriodBucketRules.for_instant(non_utc) == {:error, :invalid_utc_instant}
      assert PeriodBucketRules.for_instant(nil) == {:error, :invalid_utc_instant}

      assert PeriodBucketRules.for_instant(~N[2026-05-17 10:34:56]) ==
               {:error, :invalid_utc_instant}
    end
  end
end
