defmodule EventSalesWeb.ReadinessController do
  use EventSalesWeb, :controller

  alias EventSales.Health.DatabaseReadiness

  def show(conn, _params) do
    table = Application.get_env(:event_sales, :database_readiness_table, DatabaseReadiness)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> respond(DatabaseReadiness.status(table))
  end

  defp respond(conn, :ready), do: text(conn, "ready")
  defp respond(conn, :not_ready), do: conn |> put_status(503) |> text("not ready")
end
