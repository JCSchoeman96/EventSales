defmodule EventSales.Ingestion.FinancialReconciliation.ComparatorTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.FinancialReconciliation.Comparator
  alias EventSales.Sales.FinancialPrimitives

  @sync_run_id "11111111-1111-1111-1111-111111111111"
  @event_id "22222222-2222-2222-2222-222222222222"
  @source_system_id "33333333-3333-3333-3333-333333333333"
  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]

  describe "scope equivalence" do
    test "passes when scope fields are identical" do
      source = base_source_result()
      local = base_local_result()

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
      assert result.scope.sync_run_id == @sync_run_id
    end

    test "blocks when sync_run_id differs" do
      source = base_source_result()
      local = base_local_result() |> Map.put(:sync_run_id, "99999999-9999-9999-9999-999999999999")

      assert {:error, {:scope_mismatch, %{field: :sync_run_id}}} =
               Comparator.compare(source, local)
    end

    test "blocks when event_id differs" do
      source = base_source_result()
      local = base_local_result() |> Map.put(:event_id, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

      assert {:error, {:scope_mismatch, %{field: :event_id}}} =
               Comparator.compare(source, local)
    end

    test "blocks when source_system_id differs" do
      source = base_source_result()

      local =
        base_local_result() |> Map.put(:source_system_id, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

      assert {:error, {:scope_mismatch, %{field: :source_system_id}}} =
               Comparator.compare(source, local)
    end

    test "blocks when coverage_start differs" do
      source = base_source_result()
      local = base_local_result() |> Map.put(:coverage_start, ~U[2026-08-02 08:00:00.000000Z])

      assert {:error, {:scope_mismatch, %{field: :coverage_start}}} =
               Comparator.compare(source, local)
    end

    test "blocks when sales_covered_through differs" do
      source = base_source_result()

      local =
        base_local_result() |> Map.put(:sales_covered_through, ~U[2026-08-10 00:00:00.000000Z])

      assert {:error, {:scope_mismatch, %{field: :sales_covered_through}}} =
               Comparator.compare(source, local)
    end

    test "blocks when refunds_covered_through differs" do
      source = base_source_result()

      local =
        base_local_result() |> Map.put(:refunds_covered_through, ~U[2026-08-14 12:00:00.000000Z])

      assert {:error, {:scope_mismatch, %{field: :refunds_covered_through}}} =
               Comparator.compare(source, local)
    end

    test "blocks when a required scope field is missing" do
      source = base_source_result() |> Map.delete(:sync_run_id)
      local = base_local_result()

      assert {:error, {:invalid_scope_field, %{field: :sync_run_id, reason: :missing}}} =
               Comparator.compare(source, local)
    end

    test "blocks when a DateTime scope field is invalid" do
      source = base_source_result() |> Map.put(:coverage_start, "not-a-datetime")
      local = base_local_result()

      assert {:error,
              {:invalid_scope_field, %{field: :coverage_start, reason: :invalid_datetime}}} =
               Comparator.compare(source, local)
    end
  end

  describe "currency sets" do
    test "passes for the same one-currency set" do
      source = base_source_result()
      local = base_local_result()

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
    end

    test "passes when multi-currency maps use different insertion order" do
      source =
        base_source_result()
        |> put_in([:currencies], %{
          "USD" => currency_totals(gross_qty: "1"),
          "ZAR" => currency_totals(gross_qty: "2")
        })

      local =
        base_local_result()
        |> put_in([:currencies], %{
          "ZAR" => currency_totals(gross_qty: "2"),
          "USD" => currency_totals(gross_qty: "1")
        })

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
      assert comparison_currencies(result) == ["USD", "ZAR"]
    end

    test "blocks when source has a currency missing on local" do
      source =
        base_source_result()
        |> put_in([:currencies], %{
          "USD" => currency_totals(),
          "ZAR" => currency_totals()
        })

      local =
        base_local_result()
        |> put_in([:currencies], %{"ZAR" => currency_totals()})

      assert {:error,
              {:currency_set_mismatch,
               %{
                 source_currencies: ["USD", "ZAR"],
                 local_currencies: ["ZAR"]
               }}} = Comparator.compare(source, local)
    end

    test "blocks when local has a currency missing on source" do
      source =
        base_source_result()
        |> put_in([:currencies], %{"ZAR" => currency_totals()})

      local =
        base_local_result()
        |> put_in([:currencies], %{
          "USD" => currency_totals(),
          "ZAR" => currency_totals()
        })

      assert {:error,
              {:currency_set_mismatch,
               %{
                 source_currencies: ["ZAR"],
                 local_currencies: ["USD", "ZAR"]
               }}} = Comparator.compare(source, local)
    end

    test "matches when both currency maps are empty" do
      source = base_source_result() |> Map.put(:currencies, %{})
      local = base_local_result() |> Map.put(:currencies, %{})

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
      assert result.comparisons == []
    end

    test "retains and compares zero-valued currency partitions" do
      source =
        base_source_result()
        |> put_in([:currencies], %{"ZAR" => zero_currency_totals()})

      local =
        base_local_result()
        |> put_in([:currencies], %{"ZAR" => zero_currency_totals()})

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
      assert length(result.comparisons) == 6
    end

    test "blocks blank currency keys" do
      source = base_source_result() |> put_in([:currencies, ""], currency_totals())
      local = base_local_result()

      assert {:error, {:invalid_currency_key, %{reason: :blank}}} =
               Comparator.compare(source, local)
    end

    test "blocks non-string currency keys" do
      source = base_source_result() |> put_in([:currencies, :ZAR], currency_totals())
      local = base_local_result()

      assert {:error, {:invalid_currency_key, %{reason: :non_string}}} =
               Comparator.compare(source, local)
    end
  end

  describe "primitive comparison" do
    test "matches when all six primitives are identical" do
      source = base_source_result()
      local = base_local_result()

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
      assert Enum.all?(result.comparisons, & &1.matched?)
    end

    for {field, source_value, local_value} <- [
          {:gross_ticket_quantity, "10", "9"},
          {:gross_ticket_value, "100.00", "99.00"},
          {:refund_ticket_quantity, "2", "1"},
          {:refund_ticket_value, "20.00", "19.00"},
          {:net_ticket_quantity, "8", "7"},
          {:net_ticket_value, "80.00", "79.00"}
        ] do
      test "mismatches when #{field} differs" do
        source =
          base_source_result()
          |> put_in([:currencies, "ZAR", unquote(field)], Decimal.new(unquote(source_value)))

        local =
          base_local_result()
          |> put_in([:currencies, "ZAR", unquote(field)], Decimal.new(unquote(local_value)))

        assert {:ok, result} = Comparator.compare(source, local)
        assert result.status == :mismatched

        row =
          Enum.find(result.comparisons, fn row ->
            row.currency == "ZAR" and row.primitive == unquote(field)
          end)

        refute row.matched?
      end
    end

    test "represents multiple primitive differences deterministically" do
      source =
        base_source_result()
        |> put_in([:currencies], %{
          "USD" => currency_totals(gross_qty: "1", gross_val: "10.00"),
          "ZAR" => currency_totals(gross_qty: "2", gross_val: "20.00")
        })

      local =
        base_local_result()
        |> put_in([:currencies], %{
          "USD" => currency_totals(gross_qty: "1", gross_val: "10.01"),
          "ZAR" => currency_totals(gross_qty: "3", gross_val: "20.00")
        })

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :mismatched
      assert row_keys(result.comparisons) == expected_row_keys(["USD", "ZAR"])
      refute Enum.all?(result.comparisons, & &1.matched?)
    end

    test "blocks when a required primitive is missing" do
      source =
        base_source_result()
        |> update_in([:currencies, "ZAR"], &Map.delete(&1, :gross_ticket_quantity))

      local = base_local_result()

      assert {:error,
              {:invalid_primitive,
               %{currency: "ZAR", primitive: :gross_ticket_quantity, reason: :missing}}} =
               Comparator.compare(source, local)
    end

    test "blocks nil primitive values" do
      source =
        base_source_result()
        |> put_in([:currencies, "ZAR", :gross_ticket_quantity], nil)

      local = base_local_result()

      assert {:error,
              {:invalid_primitive,
               %{currency: "ZAR", primitive: :gross_ticket_quantity, reason: nil}}} =
               Comparator.compare(source, local)
    end

    for {bad_value, label} <- [
          {1, "integer"},
          {1.0, "float"},
          {"10", "string"}
        ] do
      test "blocks #{label} primitive values" do
        source =
          base_source_result()
          |> put_in(
            [:currencies, "ZAR", :gross_ticket_quantity],
            unquote(Macro.escape(bad_value))
          )

        local = base_local_result()

        assert {:error,
                {:invalid_primitive,
                 %{currency: "ZAR", primitive: :gross_ticket_quantity, reason: :not_decimal}}} =
                 Comparator.compare(source, local)
      end
    end
  end

  describe "decimal equality" do
    test "matches scale-equivalent decimals" do
      source =
        base_source_result()
        |> put_in([:currencies, "ZAR", :gross_ticket_value], Decimal.new("10.0"))

      local =
        base_local_result()
        |> put_in([:currencies, "ZAR", :gross_ticket_value], Decimal.new("10.00"))

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
    end

    test "mismatches one-cent differences without rounding" do
      source =
        base_source_result()
        |> put_in([:currencies, "ZAR", :gross_ticket_value], Decimal.new("10.00"))

      local =
        base_local_result()
        |> put_in([:currencies, "ZAR", :gross_ticket_value], Decimal.new("10.01"))

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :mismatched
    end

    test "matches equal negative net values" do
      source =
        base_source_result()
        |> put_in([:currencies, "ZAR", :net_ticket_quantity], Decimal.new("-1"))
        |> put_in([:currencies, "ZAR", :net_ticket_value], Decimal.new("-10.00"))

      local =
        base_local_result()
        |> put_in([:currencies, "ZAR", :net_ticket_quantity], Decimal.new("-1"))
        |> put_in([:currencies, "ZAR", :net_ticket_value], Decimal.new("-10.00"))

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
    end

    test "mismatches unequal negative net values" do
      source =
        base_source_result()
        |> put_in([:currencies, "ZAR", :net_ticket_quantity], Decimal.new("-1"))

      local =
        base_local_result()
        |> put_in([:currencies, "ZAR", :net_ticket_quantity], Decimal.new("-2"))

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :mismatched
    end
  end

  describe "comparison result shape" do
    test "matched result contains every comparison row" do
      source = base_source_result()
      local = base_local_result()

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
      assert length(result.comparisons) == 6
      assert row_keys(result.comparisons) == expected_row_keys(["ZAR"])
    end

    test "mismatched result still contains matched and mismatched rows" do
      source = base_source_result()

      local =
        base_local_result()
        |> put_in([:currencies, "ZAR", :gross_ticket_quantity], Decimal.new("9"))

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :mismatched
      assert length(result.comparisons) == 6
      assert Enum.any?(result.comparisons, & &1.matched?)
      refute Enum.all?(result.comparisons, & &1.matched?)
    end

    test "status is matched iff every row matches" do
      source = base_source_result()
      local = base_local_result()

      assert {:ok, matched} = Comparator.compare(source, local)
      assert matched.status == :matched
      assert Enum.all?(matched.comparisons, & &1.matched?)

      drifted =
        local
        |> put_in([:currencies, "ZAR", :net_ticket_value], Decimal.new("79.99"))

      assert {:ok, mismatched} = Comparator.compare(source, drifted)
      assert mismatched.status == :mismatched
    end

    test "scope is copied deterministically from validated common scope" do
      source = base_source_result()
      local = base_local_result()

      assert {:ok, result} = Comparator.compare(source, local)

      assert result.scope == %{
               sync_run_id: @sync_run_id,
               event_id: @event_id,
               source_system_id: @source_system_id,
               coverage_start: @coverage_start,
               sales_covered_through: @sales_covered_through,
               refunds_covered_through: @refunds_covered_through
             }
    end

    test "ignores source-only diagnostic transport fields" do
      source =
        base_source_result()
        |> Map.put(:source_orders_fetched, 99)
        |> Map.put(:source_refunds_fetched, 88)
        |> Map.put(:source_observed_at, ~U[2026-08-13 11:00:00.000000Z])

      local = base_local_result()

      assert {:ok, result} = Comparator.compare(source, local)
      assert result.status == :matched
    end
  end

  describe "independence" do
    test "comparator source does not reference forbidden dependencies" do
      path = "lib/event_sales/ingestion/financial_reconciliation/comparator.ex"
      source = File.read!(path)

      refute source =~ "SourceExtractor"
      refute source =~ "LocalTotals"
      refute source =~ "Repo"
      refute source =~ "WooCommerceClient"
      refute source =~ "Ash.read"
      refute source =~ "Req"
      refute source =~ "HTTPoison"
    end
  end

  defp base_source_result do
    %{
      sync_run_id: @sync_run_id,
      event_id: @event_id,
      source_system_id: @source_system_id,
      coverage_start: @coverage_start,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through,
      currencies: %{"ZAR" => currency_totals()},
      source_orders_fetched: 1,
      source_refunds_fetched: 0,
      source_observed_at: ~U[2026-08-13 11:00:00.000000Z]
    }
  end

  defp base_local_result do
    Map.drop(base_source_result(), [
      :source_orders_fetched,
      :source_refunds_fetched,
      :source_observed_at
    ])
  end

  defp currency_totals(opts \\ []) do
    gross_qty = Keyword.get(opts, :gross_qty, "10")
    gross_val = Keyword.get(opts, :gross_val, "100.00")
    refund_qty = Keyword.get(opts, :refund_qty, "2")
    refund_val = Keyword.get(opts, :refund_val, "20.00")
    net_qty = Keyword.get(opts, :net_qty, "8")
    net_val = Keyword.get(opts, :net_val, "80.00")

    %{
      gross_ticket_quantity: Decimal.new(gross_qty),
      gross_ticket_value: Decimal.new(gross_val),
      refund_ticket_quantity: Decimal.new(refund_qty),
      refund_ticket_value: Decimal.new(refund_val),
      net_ticket_quantity: Decimal.new(net_qty),
      net_ticket_value: Decimal.new(net_val)
    }
  end

  defp zero_currency_totals do
    FinancialPrimitives.empty_totals()
    |> FinancialPrimitives.derive_net_totals()
  end

  defp comparison_currencies(%{comparisons: comparisons}) do
    comparisons |> Enum.map(& &1.currency) |> Enum.uniq()
  end

  defp row_keys(comparisons) do
    Enum.map(comparisons, fn row -> {row.currency, row.primitive} end)
  end

  defp expected_row_keys(currencies) do
    for currency <- currencies,
        primitive <- FinancialPrimitives.primitives(),
        do: {currency, primitive}
  end
end
