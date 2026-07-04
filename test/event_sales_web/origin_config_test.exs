defmodule EventSalesWeb.OriginConfigTest do
  use ExUnit.Case, async: true

  alias EventSalesWeb.OriginConfig

  describe "check_origin/2" do
    test "nil env derives origin from host" do
      assert OriginConfig.check_origin("eventsales.voelgoed.co.za", nil) ==
               ["https://eventsales.voelgoed.co.za"]
    end

    test "single origin string returns one-element list" do
      assert OriginConfig.check_origin("unused.host", "https://example.com") ==
               ["https://example.com"]
    end

    test "comma-separated origins returns multiple entries" do
      env = "https://eventsales.voelgoed.co.za,https://eventsales-production.up.railway.app"

      assert OriginConfig.check_origin("unused.host", env) == [
               "https://eventsales.voelgoed.co.za",
               "https://eventsales-production.up.railway.app"
             ]
    end

    test "whitespace around origins is trimmed" do
      env = " https://a.example.com , https://b.example.com "

      assert OriginConfig.check_origin("unused.host", env) == [
               "https://a.example.com",
               "https://b.example.com"
             ]
    end

    test "empty segments are rejected" do
      env = "https://a.example.com,,https://b.example.com,"

      assert OriginConfig.check_origin("unused.host", env) == [
               "https://a.example.com",
               "https://b.example.com"
             ]
    end

    test "default host fallback produces valid origin" do
      assert OriginConfig.check_origin("example.com", nil) == ["https://example.com"]
    end
  end
end
