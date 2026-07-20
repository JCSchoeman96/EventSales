defmodule EventSales.Ingestion.CatalogChangeContractTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.CatalogChangeContract

  @valid %{
    "version" => "2026-07-20.v1",
    "signal_id" => "0190d5d4-7b86-7ae2-8d90-70ea430a87c4",
    "source" => "wordpress_tickera",
    "target_type" => "event",
    "target_id" => 123,
    "source_updated_at" => "2026-07-20T12:00:00.000000Z",
    "reason" => "saved"
  }

  test "accepts the exact PII-free contract" do
    assert {:ok, signal} = CatalogChangeContract.parse(@valid)
    assert signal.signal_id == @valid["signal_id"]
    assert signal.target_type == :event
    assert signal.target_id == 123
    assert signal.reason == :saved
    assert %DateTime{} = signal.source_updated_at
  end

  test "accepts every target and reason enum" do
    for target <- ~w(event product variation),
        reason <- ~w(saved metadata_changed status_changed trashed restored deleted) do
      assert {:ok, _} =
               CatalogChangeContract.parse(%{
                 @valid
                 | "target_type" => target,
                   "reason" => reason
               })
    end
  end

  test "rejects unknown, missing, nested, null, and invalid fields" do
    invalid = [
      Map.put(@valid, "email", "protected@example.invalid"),
      Map.delete(@valid, "reason"),
      Map.put(@valid, "reason", nil),
      Map.put(@valid, "target_id", %{"id" => 123}),
      Map.put(@valid, "target_id", 0),
      Map.put(@valid, "target_type", "order"),
      Map.put(@valid, "reason", "paid"),
      Map.put(@valid, "version", "other"),
      Map.put(@valid, "signal_id", String.upcase(@valid["signal_id"])),
      Map.put(@valid, "source_updated_at", "2026-07-20 12:00:00")
    ]

    assert Enum.all?(invalid, &(CatalogChangeContract.parse(&1) == {:error, :invalid_signal}))
  end
end
