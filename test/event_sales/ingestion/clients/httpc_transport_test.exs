defmodule EventSales.Ingestion.Clients.HttpcTransportTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.Clients.HttpcTransport

  test "POST sends a bounded raw JSON body and returns a binary response" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      request = receive_request(socket, "")
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
      send(parent, {:http_request, request})
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    body = ~s({"source_system":"550e8400-e29b-41d4-a716-446655440000"})

    assert {:ok, 200, _headers, "{}"} =
             HttpcTransport.request(
               :post,
               "http://127.0.0.1:#{port}/manifests",
               [{"x-eventsales-key-id", "order-index-key-1"}],
               body,
               timeout_ms: 1_000
             )

    assert_receive {:http_request, request}, 1_000
    assert request =~ "POST /manifests HTTP/1.1"
    assert request =~ ~r/Content-Type: application\/json/i
    assert request =~ body
  end

  defp receive_request(socket, data) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        data = data <> chunk

        if complete_request?(data) do
          data
        else
          receive_request(socket, data)
        end

      {:error, reason} ->
        flunk("local HTTP server did not receive a complete request: #{inspect(reason)}")
    end
  end

  defp complete_request?(data) do
    case :binary.match(data, "\r\n\r\n") do
      {offset, 4} ->
        headers = binary_part(data, 0, offset)
        body = binary_part(data, offset + 4, byte_size(data) - offset - 4)
        content_length = Regex.run(~r/Content-Length:\s*(\d+)/i, headers, capture: :all_but_first)

        case content_length do
          [length] -> byte_size(body) >= String.to_integer(length)
          _ -> true
        end

      :nomatch ->
        false
    end
  end
end
