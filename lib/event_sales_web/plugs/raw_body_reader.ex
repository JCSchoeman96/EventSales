defmodule EventSalesWeb.Plugs.RawBodyReader do
  @moduledoc """
  Plug.Parsers body_reader that preserves exact raw request bytes for webhook HMAC verification.

  Reads the full body (including chunked `{:more, partial, conn}` responses) before storing.
  Partial or failed reads are not stored as `:raw_body`; callers must fail closed.
  """

  @raw_body_key :raw_body

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, String.t(), Plug.Conn.t()}
  def read_body(conn, opts) do
    case read_full_body(conn, [], opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, @raw_body_key, body)
        {:ok, body, conn}

      {:error, reason, _conn} ->
        raise Plug.Parsers.ParseError, exception: reason
    end
  end

  @spec fetch_raw_body(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_raw_body}
  def fetch_raw_body(conn) do
    case conn.private[@raw_body_key] || Map.get(conn.assigns, @raw_body_key) do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end

  defp read_full_body(conn, parts, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([body | parts])), conn}

      {:more, partial, conn} ->
        read_full_body(conn, [partial | parts], opts)

      {:error, reason} ->
        {:error, reason, conn}
    end
  end
end
