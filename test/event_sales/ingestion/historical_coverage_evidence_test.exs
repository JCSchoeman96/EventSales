defmodule EventSales.Ingestion.HistoricalCoverageEvidenceTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.HistoricalCoverageEvidence

  test "builds and validates certified bounded evidence" do
    assert {:ok, evidence} = HistoricalCoverageEvidence.build(valid_attrs())

    assert evidence["schema_version"] == HistoricalCoverageEvidence.schema_version()
    assert evidence["result"] == "certified"
    assert evidence["orders"]["orders_durable"] == 4
    assert evidence["refunds"]["details_complete"] == 2
    assert HistoricalCoverageEvidence.certified?(evidence)
    assert {:ok, ^evidence} = HistoricalCoverageEvidence.validate(evidence)
  end

  test "normalizes atom-keyed reason counts and UTC evaluated_at" do
    attrs =
      valid_attrs()
      |> Map.put(:evaluated_at, ~U[2026-09-16 10:00:00.123456Z])
      |> Map.put(:result, "blocked")
      |> put_in([:orders, :blocking_unresolved_count], 2)
      |> put_in([:orders, :blocking_reasons], %{effective_time_incomplete: 2})

    assert {:ok, evidence} = HistoricalCoverageEvidence.build(attrs)
    assert evidence["evaluated_at"] == "2026-09-16T10:00:00.123456Z"
    assert evidence["orders"]["blocking_reasons"] == %{"effective_time_incomplete" => 2}
  end

  test "accepts blocked evidence and exposes its result" do
    attrs =
      valid_attrs()
      |> Map.put(:result, "blocked")
      |> put_in([:orders, :blocking_unresolved_count], 1)
      |> put_in([:orders, :blocking_reasons], %{effective_time_incomplete: 1})

    assert {:ok, evidence} = HistoricalCoverageEvidence.build(attrs)
    assert HistoricalCoverageEvidence.blocked?(evidence)
    refute HistoricalCoverageEvidence.certified?(evidence)
  end

  test "rejects malformed hashes" do
    assert {:error, :invalid_manifest_hash} =
             HistoricalCoverageEvidence.build(%{valid_attrs() | manifest_hash: "invalid"})
  end

  test "rejects missing nested evidence fields" do
    attrs = Map.update!(valid_attrs(), :orders, &Map.delete(&1, :orders_durable))

    assert {:error, {:missing_key, "orders.orders_durable"}} =
             HistoricalCoverageEvidence.build(attrs)
  end

  test "rejects negative counters" do
    attrs = put_in(valid_attrs(), [:refunds, :references_seen], -1)

    assert {:error, {:invalid_counter, "refunds.references_seen"}} =
             HistoricalCoverageEvidence.build(attrs)
  end

  test "rejects unsupported result" do
    assert {:error, :invalid_result} =
             HistoricalCoverageEvidence.build(%{valid_attrs() | result: "pending"})
  end

  test "rejects evidence that exceeds the encoded size bound" do
    reasons =
      Enum.into(1..128, %{}, fn index ->
        {"reason_#{String.pad_leading(to_string(index), 89, "0")}", 1}
      end)

    attrs =
      valid_attrs()
      |> Map.put(:manifest_terminal_evidence, String.duplicate("x", 2_048))
      |> Map.put(:catchup_terminal_evidence, String.duplicate("x", 2_048))
      |> Map.put(:result, "blocked")
      |> put_in([:orders, :blocking_unresolved_count], 128)
      |> put_in([:orders, :blocking_reasons], reasons)

    assert {:error, :evidence_too_large} = HistoricalCoverageEvidence.build(attrs)
    assert HistoricalCoverageEvidence.metadata_max_bytes() == 16_384
  end

  test "rejects extra top-level keys" do
    attrs = Map.put(valid_attrs(), :unexpected, "not allowed")

    assert {:error, {:unexpected_key, "unexpected"}} =
             HistoricalCoverageEvidence.build(attrs)
  end

  defp valid_attrs do
    %{
      manifest_hash: String.duplicate("a", 64),
      manifest_terminal_evidence: "manifest-proof",
      catchup_hash: String.duplicate("b", 64),
      catchup_terminal_evidence: "catchup-proof",
      orders: %{
        manifest_members_seen: 4,
        orders_durable: 4,
        order_items_durable: 6,
        blocking_unresolved_count: 0,
        blocking_reasons: %{}
      },
      refunds: %{
        references_seen: 2,
        details_complete: 2,
        refund_lines_durable: 2,
        blocking_unresolved_count: 0,
        blocking_reasons: %{}
      },
      result: "certified",
      evaluated_at: "2026-09-16T10:00:00.123456Z"
    }
  end
end
