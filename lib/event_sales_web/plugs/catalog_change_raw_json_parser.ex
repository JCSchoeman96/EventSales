defmodule EventSalesWeb.Plugs.CatalogChangeRawJSONParser do
  @moduledoc """
  Defers JSON decoding for catalog-change requests until after HMAC verification.

  Every other request is delegated to the remaining `Plug.Parsers` parsers.
  """

  @behaviour Plug.Parsers

  @impl true
  def init(opts) do
    {body_reader, opts} =
      Keyword.pop(opts, :body_reader, {Plug.Conn, :read_body, []})

    {body_reader, Keyword.delete(opts, :json_decoder)}
  end

  @impl true
  def parse(
        %{request_path: "/webhooks/catalog-change/" <> _rest} = conn,
        "application",
        subtype,
        _headers,
        opts
      ) do
    if subtype == "json" or String.ends_with?(subtype, "+json") do
      read_raw_body(conn, opts)
    else
      {:next, conn}
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp read_raw_body(conn, {{module, function, arguments}, opts}) do
    case apply(module, function, [conn, opts | arguments]) do
      {:ok, _raw_body, conn} -> {:ok, %{}, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, :timeout} -> raise Plug.TimeoutError
      {:error, _reason} -> raise Plug.BadRequestError
    end
  end
end
