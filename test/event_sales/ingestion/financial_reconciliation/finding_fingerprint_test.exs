defmodule EventSales.Ingestion.FinancialReconciliation.FindingFingerprintTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.FinancialReconciliation.FindingFingerprint

  test "computes deterministic lowercase 64-char SHA-256 fingerprint" do
    details = %{kind: :order, reason: "missing"}

    assert {:ok, first} = FindingFingerprint.compute(:missing_source_fact, :source, details)
    assert {:ok, second} = FindingFingerprint.compute(:missing_source_fact, :source, details)

    assert first == second
    assert byte_size(first) == 64
    assert first == String.downcase(first)
    refute first =~ ~r/[^0-9a-f]/
  end

  test "different material details produce different fingerprints" do
    assert {:ok, first} =
             FindingFingerprint.compute(:missing_source_fact, :source, %{kind: :order})

    assert {:ok, second} =
             FindingFingerprint.compute(:missing_source_fact, :source, %{kind: :refund})

    refute first == second
  end

  test "normalizes DateTime, Decimal, atom, and tuple values" do
    details = %{
      observed_at: ~U[2026-08-01 10:00:00.000000Z],
      amount: Decimal.new("12.50"),
      kind: :order,
      pair: {1, 2}
    }

    assert {:ok, normalized} = FindingFingerprint.normalize_details(details)
    assert normalized["observed_at"] == "2026-08-01T10:00:00.000000Z"
    assert normalized["amount"] == "12.50"
    assert normalized["kind"] == "order"
    assert normalized["pair"] == [1, 2]
  end

  test "unsupported detail values fail closed" do
    assert {:error, :unsupported_detail_value} =
             FindingFingerprint.normalize_details(%{bad: self()})
  end
end
