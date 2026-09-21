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

  test "boolean and nil normalization preserves JSON types" do
    assert {:ok, true} = FindingFingerprint.normalize_details(true)
    assert {:ok, false} = FindingFingerprint.normalize_details(false)
    assert {:ok, nil} = FindingFingerprint.normalize_details(nil)

    assert {:ok, %{"truncated?" => true}} =
             FindingFingerprint.normalize_details(%{truncated?: true})
  end

  test "normalizes DateTime, Decimal, atom, tuple, and nested tuple values" do
    details = %{
      observed_at: ~U[2026-08-01 10:00:00.000000Z],
      amount: Decimal.new("12.50"),
      kind: :order,
      pair: {1, 2},
      nested: {:historical_event_order_invalid, {:invalid_order_payload, :field, :reason}}
    }

    assert {:ok, normalized} = FindingFingerprint.normalize_details(details)
    assert normalized["observed_at"] == "2026-08-01T10:00:00.000000Z"
    assert normalized["amount"] == "12.50"
    assert normalized["kind"] == "order"
    assert normalized["pair"] == [1, 2]

    assert normalized["nested"] == [
             "historical_event_order_invalid",
             ["invalid_order_payload", "field", "reason"]
           ]
  end

  test "unsupported detail values fail closed without raising" do
    assert {:error, :unsupported_detail_value} =
             FindingFingerprint.normalize_details(%{bad: self()})
  end

  test "unsupported map keys fail closed without raising" do
    assert {:error, :unsupported_detail_key} =
             FindingFingerprint.normalize_details(%{self() => "value"})
  end

  test "same top-level map insertion order produces same fingerprint" do
    first = %{b: 2, a: 1}
    second = %{a: 1, b: 2}

    assert {:ok, fp1} = FindingFingerprint.compute(:missing_source_fact, :source, first)
    assert {:ok, fp2} = FindingFingerprint.compute(:missing_source_fact, :source, second)
    assert fp1 == fp2
  end

  test "same nested map insertion order produces same fingerprint" do
    first = %{outer: %{z: 3, y: 2}}
    second = %{outer: %{y: 2, z: 3}}

    assert {:ok, fp1} = FindingFingerprint.compute(:missing_source_fact, :source, first)
    assert {:ok, fp2} = FindingFingerprint.compute(:missing_source_fact, :source, second)
    assert fp1 == fp2
  end

  test "boolean true and string true produce different fingerprints" do
    assert {:ok, bool_fp} =
             FindingFingerprint.compute(:missing_source_fact, :source, %{flag: true})

    assert {:ok, string_fp} =
             FindingFingerprint.compute(:missing_source_fact, :source, %{flag: "true"})

    refute bool_fp == string_fp
  end

  test "nil and string nil produce different fingerprints" do
    assert {:ok, nil_fp} =
             FindingFingerprint.compute(:missing_source_fact, :source, %{value: nil})

    assert {:ok, string_fp} =
             FindingFingerprint.compute(:missing_source_fact, :source, %{value: "nil"})

    refute nil_fp == string_fp
  end
end
