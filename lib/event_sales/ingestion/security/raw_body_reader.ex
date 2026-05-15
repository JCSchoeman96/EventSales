defmodule EventSales.Ingestion.Security.RawBodyReader do
  @moduledoc """
  Canonical raw-body storage contract for webhook HMAC verification.
  """

  @raw_body_key :raw_body

  @spec raw_body_key() :: :raw_body
  def raw_body_key, do: @raw_body_key

  @spec put_raw_body(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def put_raw_body(conn, body) when is_binary(body) do
    Plug.Conn.put_private(conn, @raw_body_key, body)
  end

  @spec fetch_raw_body(Plug.Conn.t()) :: {:ok, binary()} | {:error, :missing_raw_body}
  def fetch_raw_body(conn) do
    case conn.private[@raw_body_key] do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end
end
