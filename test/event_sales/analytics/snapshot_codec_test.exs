defmodule EventSales.Analytics.SnapshotCodecTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.SnapshotCodec

  test "round-trips decimals datetimes and atom or string keys" do
    summary = %{
      :total_sold => 3,
      "total_revenue" => Decimal.new("123.45"),
      :today_sold => 1,
      "today_revenue" => Decimal.new("45.00"),
      :status_breakdown => %{:completed => 2, "processing" => 1},
      :updated_at => ~U[2026-05-17 10:00:00Z]
    }

    assert {:ok, encoded} = SnapshotCodec.encode(summary)
    assert {:ok, decoded} = SnapshotCodec.decode(encoded)

    assert decoded.total_sold == 3
    assert decoded.total_revenue == Decimal.new("123.45")
    assert decoded.today_sold == 1
    assert decoded.today_revenue == Decimal.new("45.00")
    assert decoded.status_breakdown == %{completed: 2, processing: 1}
    assert decoded.updated_at == ~U[2026-05-17 10:00:00Z]
  end

  test "malformed snapshots return error instead of raising" do
    malformed_inputs = [
      "{",
      Jason.encode!(%{"total_sold" => 1}),
      Jason.encode!(%{
        "total_sold" => 1,
        "total_revenue" => %{"__type__" => "decimal", "value" => "not-a-decimal"},
        "today_sold" => 0,
        "today_revenue" => %{"__type__" => "decimal", "value" => "0"},
        "status_breakdown" => %{},
        "updated_at" => %{"__type__" => "datetime", "value" => "2026-nope"}
      }),
      :not_json
    ]

    for input <- malformed_inputs do
      assert {:error, :malformed} = SnapshotCodec.decode(input)
    end
  end
end
