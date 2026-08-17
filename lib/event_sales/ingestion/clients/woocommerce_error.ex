defmodule EventSales.Ingestion.Clients.WooCommerceError do
  @moduledoc """
  Typed error returned by the WooCommerce REST boundary.
  """

  @type reason ::
          :invalid_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :client_error
          | :server_error
          | :timeout
          | :transport_error
          | :invalid_json
          | :response_mismatch
          | :misconfigured
          | :queue_timeout
          | :pagination_limit
          | :circuit_open

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t() | nil
        }

  defexception [:reason, :status, :message]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    status = Keyword.get(opts, :status)
    message = Keyword.get(opts, :message, default_message(reason, status))
    %__MODULE__{reason: reason, status: status, message: message}
  end

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message

  defp default_message(reason, nil), do: "WooCommerce REST #{reason}"
  defp default_message(reason, status), do: "WooCommerce REST #{reason} (HTTP #{status})"
end
