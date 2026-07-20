defmodule EventSalesWeb.Plugs.RawBodyReader do
  @moduledoc """
  Plug.Parsers body_reader that preserves exact raw request bytes for webhook HMAC verification.

  Reads the full body (including chunked `{:more, partial, conn}` responses) before storing.
  Partial or failed reads are not stored as raw body; callers must fail closed.
  """

  alias EventSales.Ingestion.Security.RawBodyReader, as: SecurityRawBodyReader

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, String.t(), Plug.Conn.t()}
  def read_body(conn, opts) do
    case read_full_body(conn, [], 0, opts, max_bytes(conn)) do
      {:ok, body, conn} ->
        conn = SecurityRawBodyReader.put_raw_body(conn, body)
        {:ok, body, conn}

      {:error, reason, _conn} ->
        raise Plug.Parsers.ParseError, exception: reason
    end
  end

  @spec fetch_raw_body(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_raw_body}
  def fetch_raw_body(conn), do: SecurityRawBodyReader.fetch_raw_body(conn)

  defp read_full_body(conn, parts, size, opts, max_bytes) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        if size + byte_size(body) > max_bytes,
          do: {:error, Plug.Parsers.RequestTooLargeError.exception([]), conn},
          else: {:ok, IO.iodata_to_binary(Enum.reverse([body | parts])), conn}

      {:more, partial, conn} ->
        new_size = size + byte_size(partial)

        if new_size > max_bytes,
          do: {:error, Plug.Parsers.RequestTooLargeError.exception([]), conn},
          else: read_full_body(conn, [partial | parts], new_size, opts, max_bytes)

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp max_bytes(%{request_path: "/webhooks/catalog-change/" <> _}), do: 4_096
  defp max_bytes(_conn), do: 8_000_000
end
