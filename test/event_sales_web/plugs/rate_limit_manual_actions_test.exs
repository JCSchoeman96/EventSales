defmodule EventSalesWeb.Plugs.RateLimitManualActionsTest do
  use ExUnit.Case, async: false

  alias EventSalesWeb.Plugs.RateLimitManualActions
  alias EventSalesWeb.RateLimiting.EtsSlidingWindow

  setup do
    EtsSlidingWindow.reset_for_test!()

    original =
      Application.get_env(:event_sales, :admin_http_rate_limit, [])
      |> Keyword.put(:max_requests, 1)
      |> Keyword.put(:window_ms, 60_000)

    Application.put_env(:event_sales, :admin_http_rate_limit, original)

    on_exit(fn ->
      EtsSlidingWindow.reset_for_test!()
      Application.put_env(:event_sales, :admin_http_rate_limit, original)
    end)

    :ok
  end

  test "allows the first admin login attempt" do
    conn =
      :post
      |> Plug.Test.conn("/admin/login")
      |> Map.put(:method, "POST")
      |> RateLimitManualActions.call([])

    refute conn.halted
  end

  test "returns 429 for repeated admin login attempts" do
    base_conn =
      :post
      |> Plug.Test.conn("/admin/login")
      |> Map.put(:method, "POST")

    refute RateLimitManualActions.call(base_conn, []).halted

    limited_conn = RateLimitManualActions.call(base_conn, [])

    assert limited_conn.halted
    assert limited_conn.status == 429
  end

  test "ignores non-limited routes" do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:method, "GET")
      |> RateLimitManualActions.call([])

    refute conn.halted
  end
end
