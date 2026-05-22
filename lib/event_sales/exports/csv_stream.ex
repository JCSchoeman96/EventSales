defmodule EventSales.Exports.CsvStream do
  @moduledoc """
  RFC4180 CSV encoder for lazy export streams.
  """

  alias NimbleCSV.RFC4180, as: CSV

  @spec encode_rows(Enumerable.t()) :: Enumerable.t()
  def encode_rows(rows) do
    rows
    |> Stream.map(fn row -> Enum.map(row, &format_cell/1) end)
    |> CSV.dump_to_stream()
  end

  defp format_cell(nil), do: ""
  defp format_cell(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp format_cell(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_cell(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_cell(value) when is_atom(value), do: Atom.to_string(value)
  defp format_cell(value), do: to_string(value)
end
