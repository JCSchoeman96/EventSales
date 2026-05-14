defmodule EventSales.Fixtures.WooCommerceFixtureVerificationTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias EventSales.TestSupport.FixtureVerificationHelpers

  describe "Slice 1.6 required fixture catalogue" do
    test "every required fixture file exists and declares an explicit verification status" do
      for fixture <- FixtureVerificationHelpers.required_fixtures() do
        assert File.exists?(fixture.path), "missing fixture for #{fixture.case}: #{fixture.path}"

        payload = FixtureVerificationHelpers.decode_fixture!(fixture)

        assert payload["_event_sales_fixture_status"] in [
                 "real_sanitized",
                 "synthetic_placeholder"
               ],
               "#{fixture.file} must declare _event_sales_fixture_status as real_sanitized or synthetic_placeholder"
      end
    end

    test "required synthetic placeholders are documented as blocking parser work" do
      synthetic_required_fixtures =
        FixtureVerificationHelpers.required_fixtures()
        |> Enum.filter(fn fixture ->
          fixture
          |> FixtureVerificationHelpers.decode_fixture!()
          |> Map.get("_event_sales_fixture_status") == "synthetic_placeholder"
        end)

      if synthetic_required_fixtures == [] do
        assert FixtureVerificationHelpers.parser_work_allowed?()
      else
        assert FixtureVerificationHelpers.parser_work_blocked?(),
               "required synthetic placeholders must force the exact Slice 7.0 STOP decision"
      end
    end

    test "required order fixtures include order and line-item fields needed by later parser work" do
      for fixture <- FixtureVerificationHelpers.required_fixtures(:order) do
        payload = FixtureVerificationHelpers.decode_fixture!(fixture)

        assert [] == FixtureVerificationHelpers.missing_order_paths(payload),
               "#{fixture.file} is missing required order fields"
      end
    end

    test "variation ticket fixture explicitly represents a variation id" do
      fixture = FixtureVerificationHelpers.required_fixture!(:variation_ticket_order)
      payload = FixtureVerificationHelpers.decode_fixture!(fixture)

      variation_ids =
        payload
        |> Map.fetch!("line_items")
        |> Enum.map(&Map.fetch!(&1, "variation_id"))

      assert Enum.any?(variation_ids, &(&1 not in [nil, 0])),
             "variation ticket fixture must include at least one non-zero variation_id"
    end

    test "required product fixtures include product or variation update fields" do
      for fixture <- FixtureVerificationHelpers.required_fixtures(:product) do
        payload = FixtureVerificationHelpers.decode_fixture!(fixture)

        assert [] == FixtureVerificationHelpers.missing_product_paths(payload, fixture),
               "#{fixture.file} is missing required product fields"
      end
    end
  end

  describe "committed WooCommerce fixture safety" do
    test "committed fixtures do not include raw sensitive keys or values" do
      findings =
        FixtureVerificationHelpers.committed_woocommerce_fixtures()
        |> Enum.flat_map(&FixtureVerificationHelpers.sensitive_findings/1)

      assert findings == [],
             "sensitive fixture content found:\n" <>
               Enum.map_join(findings, "\n", &FixtureVerificationHelpers.format_finding/1)
    end

    test "future-slice placeholders are outside the Slice 1.6 required cases" do
      required_files =
        FixtureVerificationHelpers.required_fixtures()
        |> MapSet.new(& &1.file)

      invalid_placeholders =
        FixtureVerificationHelpers.committed_woocommerce_fixtures()
        |> Enum.reject(fn fixture ->
          MapSet.member?(required_files, fixture.file) or
            FixtureVerificationHelpers.future_placeholder_allowed?(fixture)
        end)

      assert invalid_placeholders == [],
             "unexpected non-required placeholder fixtures: #{inspect(Enum.map(invalid_placeholders, & &1.file))}"
    end
  end
end
