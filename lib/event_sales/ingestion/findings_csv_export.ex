defmodule EventSales.Ingestion.FindingsCsvExport do
  @moduledoc """
  Bounded CSV export for admin reconciliation findings.

  Uses a local CSV escaper; does not depend on an external CSV package.
  """

  alias EventSales.Ingestion.AdminReconciliationDashboard

  @headers [
    "event",
    "source",
    "run_id",
    "finding_type",
    "severity",
    "status",
    "ticket_type",
    "woo_quantity",
    "tickera_quantity",
    "woo_order_status",
    "tickera_payment_status",
    "ticket_code",
    "checksum",
    "created_at",
    "last_seen_at",
    "resolution_reason"
  ]

  @spec build(keyword()) :: {:ok, iodata(), boolean()} | {:error, term()}
  def build(opts \\ []) do
    with {:ok, stream, truncated?} <-
           AdminReconciliationDashboard.stream_findings_for_export(opts) do
      rows =
        stream
        |> Stream.flat_map(fn
          page when is_list(page) -> page
          row when is_map(row) -> [row]
          _other -> []
        end)
        |> Enum.map(&row_to_list/1)

      body =
        [@headers | rows]
        |> Enum.map_join("\n", &encode_row/1)

      {:ok, [body, ?\n], truncated?}
    end
  end

  defp row_to_list(row) when is_map(row) do
    Enum.map(@headers, fn header ->
      row
      |> Map.get(header)
      |> format_cell()
    end)
  end

  defp format_cell(nil), do: ""
  defp format_cell(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_cell(value) when is_atom(value), do: Atom.to_string(value)
  defp format_cell(value), do: to_string(value)

  defp encode_row(cells), do: Enum.map_join(cells, ",", &escape_cell/1)

  defp escape_cell(cell) do
    cell = to_string(cell)

    if String.contains?(cell, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(cell, "\"", "\"\"") <> "\""
    else
      cell
    end
  end
end
