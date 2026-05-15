defmodule EventSalesWeb.Plugs.JsonDecoder do
  @moduledoc """
  JSON decoder for `Plug.Parsers` that does not raise on malformed JSON.

  Webhook intake validates JSON in `EventSales.Ingestion.WebhookIntake` using the
  stored raw body so invalid payloads can be logged without storing the body.
  """

  @spec decode!(binary(), keyword()) :: term()
  def decode!(body, opts \\ []) do
    case Jason.decode(body, opts) do
      {:ok, data} -> data
      {:error, _} -> %{}
    end
  end
end
