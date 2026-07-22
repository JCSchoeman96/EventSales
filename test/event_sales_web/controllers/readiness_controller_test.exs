defmodule EventSalesWeb.ReadinessControllerTest do
  use EventSalesWeb.ConnCase, async: false

  alias EventSales.Health.DatabaseReadiness

  setup do
    original_table = Application.get_env(:event_sales, :database_readiness_table)
    suffix = System.unique_integer([:positive])
    table = String.to_atom("readiness_controller_table_#{suffix}")
    server = String.to_atom("readiness_controller_server_#{suffix}")
    Application.put_env(:event_sales, :database_readiness_table, table)

    on_exit(fn ->
      if original_table,
        do: Application.put_env(:event_sales, :database_readiness_table, original_table),
        else: Application.delete_env(:event_sales, :database_readiness_table)
    end)

    %{table: table, server: server}
  end

  test "GET /ready returns ready without probing once per request", %{
    conn: conn,
    table: table,
    server: server
  } do
    counter = :atomics.new(1, [])

    probe = fn ->
      :atomics.add_get(counter, 1, 1)
      :ok
    end

    start_supervised!(
      {DatabaseReadiness, name: server, table: table, probe: probe, interval_ms: 60_000}
    )

    assert_eventually(fn -> DatabaseReadiness.status(table) == :ready end)

    for _ <- 1..5 do
      response_conn = get(recycle(conn), ~p"/ready")
      assert response(response_conn, 200) == "ready"
      assert get_resp_header(response_conn, "cache-control") == ["no-store"]
      assert get_resp_header(response_conn, "content-type") |> hd() =~ "text/plain"
    end

    assert :atomics.get(counter, 1) == 1
  end

  test "GET /ready fails closed without database details", %{conn: conn} do
    response_conn = get(conn, ~p"/ready")

    assert response(response_conn, 503) == "not ready"
    assert get_resp_header(response_conn, "cache-control") == ["no-store"]
    refute response_conn.resp_body =~ "PostgreSQL"
    refute response_conn.resp_body =~ "DATABASE_URL"
    refute response_conn.resp_body =~ "exception"
  end

  test "mutation methods are not routed to readiness", %{conn: conn} do
    for method <- [:post, :put, :patch, :delete] do
      response_conn = dispatch(recycle(conn), @endpoint, method, "/ready", nil)
      assert response(response_conn, 404) == "Not Found"
    end
  end

  test "GET /health remains static liveness", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(1)
      assert_eventually(fun, attempts - 1)
    end
  end
end
