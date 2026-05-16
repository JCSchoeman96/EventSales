defmodule EventSales.Ingestion.Clients.WooCommerceTransport do
  @moduledoc """
  Behaviour for WooCommerce REST HTTP transports.
  """

  @type method :: :get
  @type header :: {String.t(), String.t()}
  @type response ::
          {:ok, pos_integer(), [header()], binary()}
          | {:error, :timeout}
          | {:error, term()}

  @callback request(method(), String.t(), [header()], iodata() | nil, keyword()) :: response()
end
