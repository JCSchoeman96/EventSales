defmodule EventSales.TestSupport.HistoricalCoverageHelpers do
  @moduledoc false

  alias EventSales.Ingestion.HistoricalCoverageEvidence

  def certified_evidence(attrs \\ %{}) do
    defaults = %{
      manifest_hash: String.duplicate("a", 64),
      manifest_terminal_evidence: "manifest-proof",
      catchup_hash: String.duplicate("b", 64),
      catchup_terminal_evidence: "catchup-proof",
      orders: %{
        manifest_members_seen: 0,
        orders_durable: 0,
        order_items_durable: 0,
        blocking_unresolved_count: 0,
        blocking_reasons: %{}
      },
      refunds: %{
        references_seen: 0,
        details_complete: 0,
        refund_lines_durable: 0,
        blocking_unresolved_count: 0,
        blocking_reasons: %{}
      },
      result: "certified",
      evaluated_at: ~U[2026-09-16 10:00:00.000000Z]
    }

    {:ok, evidence} = HistoricalCoverageEvidence.build(deep_merge(defaults, attrs))
    evidence
  end

  def blocked_evidence(attrs \\ %{}) do
    defaults = %{
      result: "blocked",
      orders: %{
        blocking_unresolved_count: 1,
        blocking_reasons: %{coverage_blocked: 1}
      }
    }

    certified_evidence(deep_merge(defaults, attrs))
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end
end
