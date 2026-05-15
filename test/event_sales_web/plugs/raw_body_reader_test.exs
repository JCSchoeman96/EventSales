defmodule EventSalesWeb.Plugs.RawBodyReaderTest do
  use ExUnit.Case, async: true

  alias EventSalesWeb.Plugs.RawBodyReader

  test "read_body stores exact bytes for fetch_raw_body" do
    body = ~s({"id":123})
    conn = Plug.Test.conn(:post, "/", body)

    assert {:ok, ^body, conn} = RawBodyReader.read_body(conn, [])
    assert {:ok, ^body} = RawBodyReader.fetch_raw_body(conn)
  end

  test "read_body accumulates chunked reads before storing raw body" do
    body = "abcdefgh"
    conn = Plug.Test.conn(:post, "/", body)

    assert {:ok, ^body, conn} = RawBodyReader.read_body(conn, length: 3)
    assert {:ok, ^body} = RawBodyReader.fetch_raw_body(conn)
  end

  test "fetch_raw_body returns missing when body was not stored" do
    conn = Plug.Test.conn(:get, "/")

    assert {:error, :missing_raw_body} = RawBodyReader.fetch_raw_body(conn)
  end

  test "read_body does not mark raw body available when read_body was never stored" do
    conn = Plug.Test.conn(:get, "/")

    assert {:error, :missing_raw_body} = RawBodyReader.fetch_raw_body(conn)
    refute Map.has_key?(conn.private, :raw_body)
  end
end
