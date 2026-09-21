defmodule EventSales.Ingestion.FinancialReconciliation.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.FinancialReconciliation.{Comparator, Diagnostics}
  alias EventSales.Sales.FinancialPrimitives

  @sync_run_id "11111111-1111-1111-1111-111111111111"
  @event_id "22222222-2222-2222-2222-222222222222"
  @source_system_id "33333333-3333-3333-3333-333333333333"
  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]

  describe "from_comparison/1 matched" do
    test "returns matched disposition with empty lists" do
      comparison = matched_comparison()

      assert {:ok, result} = Diagnostics.from_comparison(comparison)
      assert result.disposition == :matched
      assert result.metric_mismatches == []
      assert result.structural_findings == []
    end
  end

  describe "from_comparison/1 numeric mismatches" do
    test "maps each primitive to the exact C19 category" do
      for {primitive, category} <- primitive_category_pairs() do
        comparison = mismatched_comparison(primitive)

        assert {:ok, result} = Diagnostics.from_comparison(comparison)
        assert result.disposition == :mismatched
        assert [mismatch] = result.metric_mismatches
        assert mismatch.category == category
        assert mismatch.primitive == primitive
      end
    end

    test "delta equals local minus source" do
      comparison =
        mismatched_comparison(:gross_ticket_value,
          source_value: Decimal.new("100.00"),
          local_value: Decimal.new("99.00")
        )

      assert {:ok, result} = Diagnostics.from_comparison(comparison)
      assert [mismatch] = result.metric_mismatches
      assert Decimal.equal?(mismatch.delta, Decimal.new("-1.00"))
    end

    test "retains negative delta when local is below source" do
      comparison =
        mismatched_comparison(:net_ticket_value,
          source_value: Decimal.new("80.00"),
          local_value: Decimal.new("75.00")
        )

      assert {:ok, result} = Diagnostics.from_comparison(comparison)
      assert [mismatch] = result.metric_mismatches
      assert Decimal.compare(mismatch.delta, Decimal.new("0")) == :lt
    end

    test "retains positive delta when local is above source" do
      comparison =
        mismatched_comparison(:gross_ticket_quantity,
          source_value: Decimal.new("10"),
          local_value: Decimal.new("12")
        )

      assert {:ok, result} = Diagnostics.from_comparison(comparison)
      assert [mismatch] = result.metric_mismatches
      assert Decimal.compare(mismatch.delta, Decimal.new("0")) == :gt
    end

    test "omits matched rows from metric mismatches" do
      source = base_source_result()
      local = put_in(source, [:currencies, "ZAR", :gross_ticket_value], Decimal.new("99.00"))

      assert {:ok, comparison} = Comparator.compare(source, local)
      assert {:ok, result} = Diagnostics.from_comparison(comparison)

      assert length(result.metric_mismatches) == 1
      assert result.metric_mismatches |> Enum.map(& &1.primitive) == [:gross_ticket_value]
      assert result.structural_findings == []
    end

    test "preserves M4-03 deterministic ordering for multiple mismatches" do
      source = base_source_result()

      local =
        source
        |> put_in([:currencies, "ZAR", :gross_ticket_value], Decimal.new("99.00"))
        |> put_in([:currencies, "ZAR", :net_ticket_quantity], Decimal.new("7"))

      assert {:ok, comparison} = Comparator.compare(source, local)
      assert {:ok, result} = Diagnostics.from_comparison(comparison)

      assert Enum.map(result.metric_mismatches, & &1.primitive) == [
               :gross_ticket_value,
               :net_ticket_quantity
             ]
    end

    test "does not produce structural findings for numeric inequality" do
      comparison = mismatched_comparison(:refund_ticket_value)

      assert {:ok, result} = Diagnostics.from_comparison(comparison)
      assert result.structural_findings == []
    end
  end

  describe "from_source_error/2 superseded" do
    test "source_snapshot_stale is superseded" do
      scope = base_scope()

      error =
        {:source_snapshot_stale,
         %{
           source_order_id: 10_007,
           expected: ~U[2026-08-01 10:00:00.000000Z],
           actual: ~U[2026-08-02 10:00:00.000000Z]
         }}

      assert {:ok, result} = Diagnostics.from_source_error(scope, error)
      assert result.disposition == :superseded
      assert [finding] = result.structural_findings
      assert finding.category == :source_snapshot_stale
      assert finding.origin == :source
      assert finding.details.source_order_id == 10_007
      refute Map.has_key?(finding.details, :woo_refund_ids)
    end

    test "refund_identity_drift is superseded with bounded details" do
      scope = base_scope()

      woo_ids = Enum.to_list(1..30) ++ Enum.to_list(100..124)
      expected_ids = Enum.to_list(1..30)

      error =
        {:refund_identity_drift,
         %{
           source_order_id: 10_007,
           woo_refund_ids: woo_ids,
           expected_refund_ids: expected_ids
         }}

      assert {:ok, result} = Diagnostics.from_source_error(scope, error)
      assert result.disposition == :superseded
      assert [finding] = result.structural_findings
      assert finding.category == :refund_identity_drift
      assert finding.details.source_refund_count == 55
      assert finding.details.expected_refund_count == 30
      assert length(finding.details.source_only_refund_ids) <= 20
      assert length(finding.details.expected_only_refund_ids) <= 20
      assert finding.details.truncated? == true
      refute Map.has_key?(finding.details, :woo_refund_ids)
      refute Map.has_key?(finding.details, :expected_refund_ids)
    end

    test "refund drift ID lists are deterministic" do
      scope = base_scope()

      error =
        {:refund_identity_drift,
         %{
           source_order_id: 10_007,
           woo_refund_ids: [3, 1, 2, 9],
           expected_refund_ids: [1, 2, 4]
         }}

      assert {:ok, first} = Diagnostics.from_source_error(scope, error)
      assert {:ok, second} = Diagnostics.from_source_error(scope, error)

      assert first == second

      assert first.structural_findings
             |> hd()
             |> Map.get(:details)
             |> Map.get(:source_only_refund_ids) ==
               [3, 9]

      assert first.structural_findings
             |> hd()
             |> Map.get(:details)
             |> Map.get(:expected_only_refund_ids) ==
               [4]
    end

    test "historical_certificate_not_current is superseded" do
      scope = base_scope()

      assert {:ok, result} =
               Diagnostics.from_source_error(
                 scope,
                 {:invalid_scope, %{reason: :historical_certificate_not_current}}
               )

      assert result.disposition == :superseded
      assert [finding] = result.structural_findings
      assert finding.category == :invalid_scope
      assert finding.details.reason == :historical_certificate_not_current
    end
  end

  describe "from_source_error/2 failed" do
    test "missing order maps to missing_source_fact" do
      assert_source_category(
        {:missing_source_fact, %{kind: :order, source_order_id: 10_007}},
        :missing_source_fact
      )
    end

    test "order_fetch_failed maps to missing_source_fact" do
      assert_source_category(
        {:missing_source_fact, %{kind: :order_fetch_failed, source_order_id: 10_007}},
        :missing_source_fact
      )
    end

    test "missing refund maps to missing_refund_detail" do
      assert_source_category(
        {:missing_source_fact, %{kind: :refund, source_order_id: 10_007, woo_refund_id: 99}},
        :missing_refund_detail
      )
    end

    test "refund_fetch_failed maps to missing_refund_detail" do
      assert_source_category(
        {:missing_source_fact,
         %{kind: :refund_fetch_failed, source_order_id: 10_007, woo_refund_id: 99}},
        :missing_refund_detail
      )
    end

    test "missing refund observation maps to missing_local_fact" do
      assert_source_category(
        {:missing_source_fact, %{kind: :refund_observation, source_order_id: 10_007}},
        :missing_local_fact
      )
    end

    test "refund reference inconsistency maps to missing_local_fact" do
      assert_source_category(
        {:missing_source_fact,
         %{
           kind: :refund_reference_inconsistent,
           source_order_id: 10_007,
           reference_count: 2,
           present_reference_count: 1
         }},
        :missing_local_fact
      )
    end

    test "refund reference lookup failure maps to missing_local_fact" do
      assert_source_category(
        {:missing_source_fact, %{kind: :refund_reference_lookup}},
        :missing_local_fact
      )
    end

    test "unresolved attribution" do
      assert_source_category(
        {:unresolved_attribution, %{reason: :unknown_parent_line_binder, woo_order_id: 10}},
        :unresolved_attribution
      )
    end

    test "timestamp incomplete" do
      assert_source_category(
        {:timestamp_incomplete, %{field: :source_created_at, boundary: @refunds_covered_through}},
        :timestamp_incomplete
      )
    end

    test "invalid currency maps to currency_conflict" do
      assert_source_category({:invalid_currency, %{field: :currency}}, :currency_conflict)
    end

    test "financial primitive incomplete" do
      assert_source_category(
        {:financial_primitive_incomplete,
         %{field: :quantity, woo_line_item_id: 1, woo_order_id: 10, reason: :missing}},
        :financial_primitive_incomplete
      )
    end

    test "historical recognition unproven" do
      assert_source_category(
        {:historical_recognition_unproven, %{woo_order_id: 10}},
        :historical_recognition_unproven
      )
    end

    test "http_under_lock" do
      assert_source_category({:http_under_lock, %{source_order_id: 10_007}}, :http_under_lock)
    end

    test "other invalid scope maps to invalid_scope" do
      assert_source_category({:invalid_scope, %{reason: :event_mismatch}}, :invalid_scope)
    end
  end

  describe "from_local_error/2" do
    test "missing order maps to missing_local_fact" do
      assert_local_category(
        {:missing_local_fact, %{kind: :order, source_order_id: 10_007}},
        :missing_local_fact
      )
    end

    test "missing refund observation maps to missing_local_fact" do
      assert_local_category(
        {:missing_local_fact, %{kind: :refund_observation, source_order_id: 10_007}},
        :missing_local_fact
      )
    end

    test "refund reference inconsistency maps to missing_local_fact" do
      assert_local_category(
        {:missing_local_fact,
         %{
           kind: :refund_reference_inconsistent,
           source_order_id: 10_007,
           reference_count: 2,
           present_reference_count: 1
         }},
        :missing_local_fact
      )
    end

    test "missing refund maps to missing_refund_detail" do
      assert_local_category(
        {:missing_local_fact, %{kind: :refund, source_order_id: 10_007, woo_refund_id: 99}},
        :missing_refund_detail
      )
    end

    test "incomplete refund maps to missing_refund_detail" do
      assert_local_category(
        {:missing_local_fact,
         %{kind: :refund_not_complete, source_order_id: 10_007, woo_refund_id: 99}},
        :missing_refund_detail
      )
    end

    test "inactive refund maps to missing_local_fact" do
      assert_local_category(
        {:missing_local_fact,
         %{kind: :refund_not_active, source_order_id: 10_007, woo_refund_id: 99}},
        :missing_local_fact
      )
    end

    test "refund parent binding maps to missing_local_fact" do
      assert_local_category(
        {:missing_local_fact,
         %{kind: :refund_parent_binding, source_order_id: 10_007, woo_refund_id: 99}},
        :missing_local_fact
      )
    end

    test "unresolved attribution" do
      assert_local_category(
        {:unresolved_attribution,
         %{source_order_id: 10_007, woo_refund_id: 99, reason: :binding}},
        :unresolved_attribution
      )
    end

    test "timestamp incomplete" do
      assert_local_category(
        {:timestamp_incomplete,
         %{field: :source_created_at, source_order_id: 10_007, woo_refund_id: 99}},
        :timestamp_incomplete
      )
    end

    test "currency conflict" do
      assert_local_category(
        {:currency_conflict, %{source_order_id: 10_007, field: :currency}},
        :currency_conflict
      )
    end

    test "financial primitive incomplete" do
      assert_local_category(
        {:financial_primitive_incomplete,
         %{field: :quantity, woo_line_item_id: 1, source_order_id: 10_007, reason: :missing}},
        :financial_primitive_incomplete
      )
    end

    test "historical recognition unproven" do
      assert_local_category(
        {:historical_recognition_unproven, %{source_order_id: 10_007}},
        :historical_recognition_unproven
      )
    end

    test "historical_certificate_not_current is superseded" do
      assert {:ok, result} =
               Diagnostics.from_local_error(
                 base_scope(),
                 {:invalid_scope, %{reason: :historical_certificate_not_current}}
               )

      assert result.disposition == :superseded
      assert [finding] = result.structural_findings
      assert finding.category == :invalid_scope
    end
  end

  describe "from_comparator_error/2" do
    test "currency_set_mismatch is mismatched with currency_conflict finding" do
      scope = base_scope()

      error =
        {:currency_set_mismatch,
         %{
           source_currencies: ["EUR", "ZAR"],
           local_currencies: ["ZAR"]
         }}

      assert {:ok, result} = Diagnostics.from_comparator_error(scope, error)
      assert result.disposition == :mismatched
      assert [finding] = result.structural_findings
      assert finding.category == :currency_conflict
      assert finding.origin == :comparator
      assert finding.details.source_currencies == ["EUR", "ZAR"]
      assert finding.details.local_currencies == ["ZAR"]
    end

    test "scope_mismatch is failed with comparison_scope_mismatch" do
      assert_comparator_category(
        {:scope_mismatch, %{field: :sync_run_id, source: "a", local: "b"}},
        :failed,
        :comparison_scope_mismatch
      )
    end

    test "invalid_scope_field is failed with invalid_comparison_input" do
      assert_comparator_category(
        {:invalid_scope_field, %{field: :sync_run_id, reason: :missing}},
        :failed,
        :invalid_comparison_input
      )
    end

    test "invalid primitive is failed with invalid_comparison_input" do
      assert_comparator_category(
        {:invalid_primitive,
         %{currency: "ZAR", primitive: :gross_ticket_value, reason: :missing}},
        :failed,
        :invalid_comparison_input
      )
    end
  end

  describe "malformed input" do
    test "unknown source error blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :unknown_source_error}}} =
               Diagnostics.from_source_error(base_scope(), {:totally_unknown, %{}})
    end

    test "unknown local error blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :unknown_local_error}}} =
               Diagnostics.from_local_error(base_scope(), {:totally_unknown, %{}})
    end

    test "unknown comparator error blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :unknown_comparator_error}}} =
               Diagnostics.from_comparator_error(base_scope(), {:totally_unknown, %{}})
    end

    test "unknown missing_source_fact kind blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :unknown_missing_source_fact_kind}}} =
               Diagnostics.from_source_error(
                 base_scope(),
                 {:missing_source_fact, %{kind: :alien}}
               )
    end

    test "unknown missing_local_fact kind blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :unknown_missing_local_fact_kind}}} =
               Diagnostics.from_local_error(base_scope(), {:missing_local_fact, %{kind: :alien}})
    end

    test "invalid comparison result shape blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :invalid_comparison_result_shape}}} =
               Diagnostics.from_comparison(%{status: :matched})
    end

    test "malformed scope blocks" do
      assert {:error, {:invalid_diagnostic_input, %{reason: :missing_scope_field}}} =
               Diagnostics.from_source_error(%{}, {:http_under_lock, %{}})
    end
  end

  describe "bounded details" do
    test "does not propagate arbitrary upstream keys" do
      error =
        {:http_under_lock,
         %{
           source_order_id: 10_007,
           customer_email: "secret@example.com",
           raw_payload: %{"id" => 1}
         }}

      assert {:ok, result} = Diagnostics.from_source_error(base_scope(), error)
      details = hd(result.structural_findings).details

      assert details.source_order_id == 10_007
      refute Map.has_key?(details, :customer_email)
      refute Map.has_key?(details, :raw_payload)
    end
  end

  describe "independence" do
    test "diagnostics source does not reference forbidden dependencies" do
      path = "lib/event_sales/ingestion/financial_reconciliation/diagnostics.ex"
      source = File.read!(path)

      refute source =~ "SourceExtractor"
      refute source =~ "LocalTotals"
      refute source =~ "Comparator"
      refute source =~ "Repo"
      refute source =~ "WooCommerceClient"
      refute source =~ "Ash.read"
      refute source =~ "Req"
      refute source =~ "HTTPoison"
      refute source =~ "Oban"
    end
  end

  defp assert_source_category(error, expected_category) do
    assert {:ok, result} = Diagnostics.from_source_error(base_scope(), error)
    assert result.disposition == :failed
    assert [finding] = result.structural_findings
    assert finding.category == expected_category
    assert finding.origin == :source
    assert finding.scope == base_scope()
  end

  defp assert_local_category(error, expected_category) do
    assert {:ok, result} = Diagnostics.from_local_error(base_scope(), error)
    assert result.disposition == :failed
    assert [finding] = result.structural_findings
    assert finding.category == expected_category
    assert finding.origin == :local
  end

  defp assert_comparator_category(error, expected_disposition, expected_category) do
    assert {:ok, result} = Diagnostics.from_comparator_error(base_scope(), error)
    assert result.disposition == expected_disposition
    assert [finding] = result.structural_findings
    assert finding.category == expected_category
    assert finding.origin == :comparator
  end

  defp base_scope do
    %{
      sync_run_id: @sync_run_id,
      event_id: @event_id,
      source_system_id: @source_system_id,
      coverage_start: @coverage_start,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through
    }
  end

  defp base_source_result do
    %{
      sync_run_id: @sync_run_id,
      event_id: @event_id,
      source_system_id: @source_system_id,
      coverage_start: @coverage_start,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through,
      currencies: %{"ZAR" => currency_totals()}
    }
  end

  defp currency_totals do
    %{
      gross_ticket_quantity: Decimal.new("10"),
      gross_ticket_value: Decimal.new("100.00"),
      refund_ticket_quantity: Decimal.new("2"),
      refund_ticket_value: Decimal.new("20.00"),
      net_ticket_quantity: Decimal.new("8"),
      net_ticket_value: Decimal.new("80.00")
    }
  end

  defp matched_comparison do
    source = base_source_result()
    local = Map.drop(source, [])

    {:ok, comparison} = Comparator.compare(source, local)
    comparison
  end

  defp mismatched_comparison(primitive, opts \\ []) do
    source_value = Keyword.get(opts, :source_value, Decimal.new("100.00"))
    local_value = Keyword.get(opts, :local_value, Decimal.new("99.00"))

    comparisons =
      for currency <- ["ZAR"],
          p <- FinancialPrimitives.primitives() do
        values =
          if p == primitive do
            {source_value, local_value, false}
          else
            shared = Decimal.new("1")
            {shared, shared, true}
          end

        {src, loc, matched?} = values

        %{
          currency: currency,
          primitive: p,
          source_value: src,
          local_value: loc,
          matched?: matched?
        }
      end

    %{
      status: :mismatched,
      scope: base_scope(),
      comparisons: comparisons
    }
  end

  defp primitive_category_pairs do
    [
      {:gross_ticket_quantity, :gross_quantity_mismatch},
      {:gross_ticket_value, :gross_value_mismatch},
      {:refund_ticket_quantity, :refund_quantity_mismatch},
      {:refund_ticket_value, :refund_value_mismatch},
      {:net_ticket_quantity, :net_quantity_mismatch},
      {:net_ticket_value, :net_value_mismatch}
    ]
  end
end
