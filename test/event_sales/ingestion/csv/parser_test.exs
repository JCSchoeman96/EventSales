defmodule EventSales.Ingestion.Csv.ParserTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.Csv.Parser

  @required_headers [
    "woo_order_id",
    "order_number",
    "woo_line_item_id",
    "woo_product_id",
    "quantity",
    "line_subtotal",
    "line_total",
    "order_raw_total",
    "status",
    "currency",
    "created_at_source",
    "updated_at_source"
  ]

  test "streams RFC4180 rows with copied headers and cells" do
    path =
      write_csv!("""
      #{Enum.join(@required_headers ++ ["name"], ",")}
      10001,ES-10001,70001,501,2,1000.00,900.00,900.00,completed,ZAR,2026-05-01T08:00:00,2026-05-01T08:05:00,"General, Admission"
      """)

    assert {:ok, stream} = Parser.stream_rows(path)
    assert [%{row_number: 2, raw: row}] = Enum.to_list(stream)
    assert row["name"] == "General, Admission"
    assert row["woo_order_id"] == "10001"
  end

  test "rejects duplicate headers" do
    path =
      write_csv!("""
      woo_order_id,woo_order_id,order_number
      10001,10001,ES-10001
      """)

    assert {:error, {:duplicate_headers, ["woo_order_id"]}} = Parser.stream_rows(path)
  end

  test "rejects missing required headers before rows are consumed" do
    path =
      write_csv!("""
      woo_order_id,order_number
      10001,ES-10001
      """)

    assert {:error, {:missing_required_headers, missing}} = Parser.stream_rows(path)
    assert "woo_line_item_id" in missing
    assert "order_raw_total" in missing
    refute "raw_total" in missing
  end

  test "rejects forbidden legacy headers" do
    path =
      write_csv!("""
      #{Enum.join(@required_headers ++ ["raw_total", "discount_total"], ",")}
      10001,ES-10001,70001,501,2,1000.00,900.00,900.00,completed,ZAR,2026-05-01T08:00:00,2026-05-01T08:05:00,900.00,0.00
      """)

    assert {:error, {:forbidden_headers, forbidden}} = Parser.stream_rows(path)
    assert forbidden == ["discount_total", "raw_total"]
  end

  test "accepts V3 order total headers" do
    path =
      write_csv!("""
      #{Enum.join(@required_headers ++ ["order_raw_discount_total", "order_raw_tax_total"], ",")}
      10001,ES-10001,70001,501,2,1000.00,900.00,900.00,completed,ZAR,2026-05-01T08:00:00,2026-05-01T08:05:00,0.00,0.00
      """)

    assert {:ok, stream} = Parser.stream_rows(path)
    assert [%{raw: row}] = Enum.to_list(stream)
    assert row["order_raw_total"] == "900.00"
    assert row["order_raw_discount_total"] == "0.00"
    assert row["order_raw_tax_total"] == "0.00"
  end

  test "large files remain enumerable for chunked consumers" do
    path =
      1..2_000
      |> Enum.map(fn index ->
        [
          20_000 + index,
          "ES-#{20_000 + index}",
          80_000 + index,
          501,
          1,
          "100.00",
          "100.00",
          "100.00",
          "completed",
          "ZAR",
          "2026-05-01T08:00:00",
          "2026-05-01T08:05:00"
        ]
        |> Enum.join(",")
      end)
      |> then(fn rows ->
        write_csv!(Enum.join([Enum.join(@required_headers, ",") | rows], "\n") <> "\n")
      end)

    assert {:ok, stream} = Parser.stream_rows(path)

    chunk_sizes =
      stream
      |> Stream.chunk_every(500)
      |> Enum.map(&length/1)

    assert chunk_sizes == [500, 500, 500, 500]
  end

  defp write_csv!(contents) do
    path = Path.join(System.tmp_dir!(), "event-sales-parser-#{System.unique_integer()}.csv")
    File.write!(path, contents)
    path
  end
end
