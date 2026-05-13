defmodule EventSalesWeb.PageControllerTest do
  use EventSalesWeb.ConnCase

  @csp_header [
    "default-src 'self'; base-uri 'self'; frame-ancestors 'self'; form-action 'self'; " <>
      "img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'; " <>
      "connect-src 'self'"
  ]

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
    assert get_resp_header(conn, "content-security-policy") == @csp_header
  end
end
