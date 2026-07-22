defmodule EventSalesWeb.Plugs.CatalogChangeRawJSONParserTest do
  use ExUnit.Case, async: true

  alias EventSalesWeb.Plugs.{CatalogChangeRawJSONParser, RawBodyReader}

  @parser_opts [
    body_reader: {RawBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()
  ]

  test "handles catalog-change JSON without decoding and preserves exact raw bytes" do
    body = ~s({"truncated":)

    conn =
      :post
      |> Plug.Test.conn("/webhooks/catalog-change/token", body)
      |> Plug.Conn.put_req_header("content-type", "application/json; charset=utf-8")

    opts = CatalogChangeRawJSONParser.init(@parser_opts)

    assert {:ok, %{}, parsed_conn} =
             CatalogChangeRawJSONParser.parse(
               conn,
               "application",
               "json",
               %{"charset" => "utf-8"},
               opts
             )

    assert {:ok, ^body} = RawBodyReader.fetch_raw_body(parsed_conn)
  end

  test "delegates non-catalog JSON without consuming its body" do
    body = ~s({"name":"unchanged"})
    conn = Plug.Test.conn(:post, "/api/example", body)
    opts = CatalogChangeRawJSONParser.init(@parser_opts)

    assert {:next, ^conn} =
             CatalogChangeRawJSONParser.parse(conn, "application", "json", %{}, opts)

    json_opts = Plug.Parsers.JSON.init(@parser_opts)

    assert {:ok, %{"name" => "unchanged"}, _conn} =
             Plug.Parsers.JSON.parse(conn, "application", "json", %{}, json_opts)
  end

  test "delegates non-JSON catalog-change requests" do
    conn = Plug.Test.conn(:post, "/webhooks/catalog-change/token", "plain text")
    opts = CatalogChangeRawJSONParser.init(@parser_opts)

    assert {:next, ^conn} =
             CatalogChangeRawJSONParser.parse(conn, "text", "plain", %{}, opts)
  end
end
