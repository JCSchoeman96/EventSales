defmodule EventSalesWeb.Admin.ReconciliationExportController do
  @moduledoc """
  Streams a bounded CSV export of reconciliation findings for admins.
  """

  use EventSalesWeb, :controller

  alias EventSales.Ingestion.FindingsCsvExport

  def show(conn, params) do
    opts =
      params
      |> filter_params()
      |> Keyword.put(:actor, conn.assigns.current_user)

    case FindingsCsvExport.build(opts) do
      {:ok, body, truncated?} ->
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="reconciliation-findings.csv")
        )
        |> put_resp_header("x-event-sales-export-truncated", truncated_header(truncated?))
        |> send_resp(200, body)

      {:error, :forbidden} ->
        send_resp(conn, 403, "Forbidden")
    end
  end

  defp filter_params(params) do
    [
      event_id: params["event_id"],
      tickera_event_source_id: params["tickera_event_source_id"],
      tickera_reconciliation_run_id: params["tickera_reconciliation_run_id"],
      ticket_type_id: params["ticket_type_id"],
      status: params["status"],
      severity: params["severity"],
      finding_type: params["finding_type"],
      woo_order_status: params["woo_order_status"],
      tickera_payment_status: params["tickera_payment_status"],
      last_seen_from: params["last_seen_from"],
      last_seen_to: params["last_seen_to"]
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp truncated_header(true), do: "true"
  defp truncated_header(false), do: "false"
end
