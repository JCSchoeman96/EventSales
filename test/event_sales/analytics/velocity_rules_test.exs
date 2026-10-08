defmodule EventSales.Analytics.VelocityRulesTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.VelocityRules

  describe "rate_per_hour/2" do
    test "normalizes locked window durations to per-hour rates" do
      assert VelocityRules.rate_per_hour(Decimal.new("1"), 900) == {:ok, Decimal.new("4")}
      assert VelocityRules.rate_per_hour(Decimal.new("1"), 1800) == {:ok, Decimal.new("2")}
      assert VelocityRules.rate_per_hour(Decimal.new("1"), 3600) == {:ok, Decimal.new("1")}
    end

    test "scales decimal raw values without rounding" do
      assert {:ok, fifteen} = VelocityRules.rate_per_hour(Decimal.new("2.5"), 900)
      assert {:ok, thirty} = VelocityRules.rate_per_hour(Decimal.new("2.5"), 1800)
      assert Decimal.equal?(fifteen, Decimal.new("10"))
      assert Decimal.equal?(thirty, Decimal.new("5"))
    end

    test "rejects non-positive window durations" do
      assert VelocityRules.rate_per_hour(Decimal.new("1"), 0) ==
               {:error, :invalid_window_duration}

      assert VelocityRules.rate_per_hour(Decimal.new("1"), -60) ==
               {:error, :invalid_window_duration}
    end
  end

  describe "compare_rates/2" do
    test "direction follows exact sign of current minus previous" do
      assert VelocityRules.compare_rates(Decimal.new("5"), Decimal.new("3")).direction == :faster
      assert VelocityRules.compare_rates(Decimal.new("3"), Decimal.new("3")).direction == :flat
      assert VelocityRules.compare_rates(Decimal.new("2"), Decimal.new("3")).direction == :slower
    end

    test "zero versus zero is flat with nil percentage delta" do
      result = VelocityRules.compare_rates(Decimal.new("0"), Decimal.new("0"))

      assert result.direction == :flat
      assert Decimal.equal?(result.absolute_delta, Decimal.new("0"))
      assert result.percentage_delta == nil
    end

    test "positive versus zero baseline uses M5-04 zero-denominator semantics" do
      result = VelocityRules.compare_rates(Decimal.new("10"), Decimal.new("0"))

      assert result.direction == :faster
      assert Decimal.equal?(result.absolute_delta, Decimal.new("10"))
      assert result.percentage_delta == nil
    end

    test "zero versus positive previous is slower with M5-04 percentage semantics" do
      result = VelocityRules.compare_rates(Decimal.new("0"), Decimal.new("4"))

      assert result.direction == :slower
      assert Decimal.equal?(result.absolute_delta, Decimal.new("-4"))
      assert Decimal.equal?(result.percentage_delta, Decimal.new("-100"))
    end

    test "negative net rates remain unclamped and percentage uses M5-04 arithmetic" do
      result = VelocityRules.compare_rates(Decimal.new("-20"), Decimal.new("-50"))

      assert result.direction == :faster
      assert Decimal.equal?(result.absolute_delta, Decimal.new("30"))
      assert Decimal.equal?(result.percentage_delta, Decimal.new("-60"))
    end

    test "non-zero previous yields percentage delta under M5-04 available semantics" do
      result = VelocityRules.compare_rates(Decimal.new("125"), Decimal.new("100"))

      assert result.direction == :faster
      assert Decimal.equal?(result.absolute_delta, Decimal.new("25"))
      assert Decimal.equal?(result.percentage_delta, Decimal.new("25.00"))
    end
  end
end
