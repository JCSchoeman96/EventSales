defmodule EventSalesWeb.HealthController do
  use EventSalesWeb, :controller

  def show(conn, _params) do
    text(conn, "ok")
  end
end
