defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedError do
  @moduledoc """
  Internal error struct for WordPress Tickera catalog feed classification.

  Public feed APIs return safe atoms. This struct is available only for internal
  use where richer status context is helpful.
  """

  defexception [:reason, :status]

  @type reason ::
          :invalid_scope
          | :misconfigured
          | :invalid_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :timeout
          | :server_error
          | :invalid_json
          | :invalid_feed_response
          | :pagination_limit
          | :transport_error

  @type t :: %__MODULE__{reason: reason(), status: pos_integer() | nil}

  @impl true
  def message(%__MODULE__{reason: reason}), do: to_string(reason)
end
