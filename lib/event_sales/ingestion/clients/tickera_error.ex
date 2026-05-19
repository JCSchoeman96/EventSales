defmodule EventSales.Ingestion.Clients.TickeraError do
  @moduledoc """
  Typed error returned by the Tickera attendee API boundary.
  """

  @type reason ::
          :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :client_error
          | :server_error
          | :timeout
          | :transport_error
          | :invalid_json
          | :misconfigured
          | :invalid_request

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          operation: atom() | nil,
          message: String.t() | nil,
          retryable?: boolean()
        }

  defexception [:reason, :status, :operation, :message, :retryable?]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    status = Keyword.get(opts, :status)
    operation = Keyword.get(opts, :operation)
    retryable? = Keyword.get(opts, :retryable?, retryable?(reason))
    message = Keyword.get(opts, :message, default_message(reason, status, operation))

    %__MODULE__{
      reason: reason,
      status: status,
      operation: operation,
      message: message,
      retryable?: retryable?
    }
  end

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message

  @spec retryable?(reason()) :: boolean()
  def retryable?(reason)
      when reason in [:rate_limited, :server_error, :timeout, :transport_error],
      do: true

  def retryable?(_reason), do: false

  defp default_message(reason, nil, nil), do: "Tickera API #{reason}"
  defp default_message(reason, nil, operation), do: "Tickera API #{operation} #{reason}"
  defp default_message(reason, status, nil), do: "Tickera API #{reason} (HTTP #{status})"

  defp default_message(reason, status, operation),
    do: "Tickera API #{operation} #{reason} (HTTP #{status})"
end
