defmodule EventSales.Ingestion.Csv.Parser do
  @moduledoc """
  Streaming RFC4180 parser for CSV import dry-runs.
  """

  alias NimbleCSV.RFC4180, as: CSV

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

  @optional_headers [
    "woo_variation_id",
    "name",
    "line_discount_total",
    "completed_at",
    "customer_name",
    "customer_email",
    "order_raw_discount_total",
    "order_raw_tax_total",
    "payment_method",
    "payment_method_title",
    "payment_gateway_transaction_id"
  ]

  @type parsed_row :: %{row_number: pos_integer(), raw: %{String.t() => String.t()}}

  @doc "Required Slice 16 CSV headers."
  @spec required_headers() :: [String.t()]
  def required_headers, do: @required_headers

  @doc "All accepted Slice 16 CSV headers."
  @spec accepted_headers() :: [String.t()]
  def accepted_headers, do: @required_headers ++ @optional_headers

  @doc """
  Returns a lazy stream of parsed CSV rows after validating the header row.
  """
  @spec stream_rows(Path.t()) ::
          {:ok, Enumerable.t()} | {:error, {:duplicate_headers, [String.t()]}} | {:error, term()}
  def stream_rows(path) when is_binary(path) do
    with {:ok, headers} <- read_headers(path),
         :ok <- reject_duplicate_headers(headers),
         :ok <- require_headers(headers) do
      stream =
        path
        |> File.stream!(:line)
        |> CSV.parse_stream(skip_headers: true)
        |> Stream.with_index(2)
        |> Stream.map(fn {row, row_number} ->
          %{row_number: row_number, raw: zip_row(headers, row)}
        end)

      {:ok, stream}
    end
  rescue
    error in NimbleCSV.ParseError -> {:error, {:invalid_csv, Exception.message(error)}}
    error in File.Error -> {:error, {:file_error, Exception.message(error)}}
  end

  defp read_headers(path) do
    path
    |> File.stream!(:line)
    |> CSV.parse_stream(skip_headers: false)
    |> Enum.take(1)
    |> case do
      [headers] -> {:ok, Enum.map(headers, &copy_trim/1)}
      [] -> {:error, :empty_csv}
    end
  end

  defp reject_duplicate_headers(headers) do
    duplicates =
      headers
      |> Enum.frequencies()
      |> Enum.filter(fn {_header, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case duplicates do
      [] -> :ok
      duplicates -> {:error, {:duplicate_headers, duplicates}}
    end
  end

  defp require_headers(headers) do
    missing = @required_headers -- headers

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_required_headers, missing}}
    end
  end

  defp zip_row(headers, row) do
    headers
    |> Enum.zip(row)
    |> Map.new(fn {header, value} -> {header, copy_trim(value)} end)
  end

  defp copy_trim(value) when is_binary(value), do: value |> String.trim() |> :binary.copy()
end
