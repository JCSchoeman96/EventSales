defmodule EventSalesWeb.HealthControllerTest do
  use EventSalesWeb.ConnCase, async: true

  test "GET /health returns 200 without browser pipeline state", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == "ok"
    assert conn.private[:phoenix_root_layout] == nil
  end
end
