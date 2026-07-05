defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedSignatureTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.WordPressFeedSignature

  test "builds VS-26C-compatible HMAC headers" do
    query = %{"per_page" => 100, "product_id" => 109_740, "page" => 1}
    secret = "test-feed-secret"

    base =
      "GET\n/wp-json/eventsales/v1/tickera-catalog\npage=1&per_page=100&product_id=109740\n1780000000"

    expected = "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, base), case: :lower)

    assert {:ok, headers} =
             WordPressFeedSignature.headers(
               :get,
               "/wp-json/eventsales/v1/tickera-catalog",
               query,
               secret,
               1_780_000_000
             )

    assert {"x-eventsales-timestamp", "1780000000"} in headers
    assert {"x-eventsales-signature", expected} in headers
    assert {"accept", "application/json"} in headers
  end

  test "canonical query drops nils, sorts keys, and uses RFC3986 encoding" do
    assert {:ok, "page=1&per_page=100&ticket_display_name=Early%20Bird"} =
             WordPressFeedSignature.canonical_query(%{
               per_page: 100,
               page: 1,
               ignored: nil,
               ticket_display_name: "Early Bird"
             })
  end

  test "canonical query rejects non-scalar params without leaking secrets" do
    assert {:error, :invalid_request} =
             WordPressFeedSignature.canonical_query(%{"product_id" => [109_740]})

    assert {:error, :invalid_request} =
             WordPressFeedSignature.headers(:get, "/path", %{"nested" => %{}}, "secret", 123)
  end
end
