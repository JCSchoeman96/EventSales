defmodule EventSalesWeb.HealthControllerTest do
  use EventSalesWeb.ConnCase, async: true

  test "GET /health returns 200", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == "ok"
  end
end
