defmodule EventSalesWeb.Admin.EventExportController do
  @moduledoc """
  Streams event-scoped Slice 18 CSV exports for admins.
  """

  use EventSalesWeb, :controller

  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Exports.EventSalesCsv

  def summary(conn, %{"event_id" => event_id} = params) do
    stream_export(conn, event_id, :summary, params)
  end

  def orders(conn, %{"event_id" => event_id} = params) do
    stream_export(conn, event_id, :orders, params)
  end

  defp stream_export(conn, event_id, export_type, params) do
    opts = [actor: conn.assigns.current_user, max_rows: params["max_rows"]]

    result =
      case export_type do
        :summary -> EventSalesCsv.summary_csv(event_id, opts)
        :orders -> EventSalesCsv.orders_csv(event_id, opts)
      end

    case result do
      {:ok, chunks, truncated?} ->
        with {:ok, _audit} <- audit_request(conn, event_id, export_type) do
          conn
          |> put_resp_content_type("text/csv")
          |> put_resp_header("content-disposition", content_disposition(event_id, export_type))
          |> put_resp_header("x-event-sales-export-truncated", truncated_header(truncated?))
          |> send_resp_chunks(chunks)
        end

      {:error, :forbidden} ->
        send_resp(conn, 403, "Forbidden")

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp audit_request(conn, event_id, export_type) do
    AuditLogger.event_sales_export_requested(%{
      actor_type: :user,
      actor_user_id: conn.assigns.current_user.id,
      actor_role: :admin,
      event_id: event_id,
      subject_type: "event",
      subject_id: event_id,
      source: :admin,
      metadata: %{
        event_id: event_id,
        export_type: Atom.to_string(export_type),
        actor_user_id: conn.assigns.current_user.id,
        actor_role: "admin",
        source: "admin",
        pii_policy: "no_pii"
      }
    })
  end

  defp send_resp_chunks(conn, chunks) do
    conn = send_chunked(conn, 200)

    Enum.reduce_while(chunks, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp content_disposition(event_id, :summary),
    do: ~s(attachment; filename="event-summary-#{event_id}.csv")

  defp content_disposition(event_id, :orders),
    do: ~s(attachment; filename="event-orders-#{event_id}.csv")

  defp truncated_header(true), do: "true"
  defp truncated_header(false), do: "false"
end
