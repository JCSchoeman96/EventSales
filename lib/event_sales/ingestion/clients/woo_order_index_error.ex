defmodule EventSales.Ingestion.Clients.WooOrderIndexError do
  @moduledoc """
  Bounded error returned by the Woo order-index HTTP boundary.

  The struct deliberately stores only a classified reason and optional HTTP
  status. It never carries request credentials, signed material, URLs, or
  response bodies.
  """

  @type reason ::
          :misconfigured
          | :invalid_request
          | :unauthorized
          | :busy
          | :manifest_expired
          | :manifest_not_found
          | :manifest_unavailable
          | :source_authority_changed
          | :capture_budget_exceeded
          | :manifest_storage_failed
          | :manifest_finalize_failed
          | :source_preflight_failed
          | :source_snapshot_failed
          | :lock_unavailable
          | :server_error
          | :invalid_json
          | :invalid_response
          | :timeout
          | :transport_error
          | :ambiguous_create

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          message: String.t()
        }

  defexception [:reason, :status, :message]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    status = Keyword.get(opts, :status)

    %__MODULE__{
      reason: reason,
      status: status,
      message: default_message(reason, status)
    }
  end

  @impl true
  def message(%__MODULE__{message: message}), do: message

  defp default_message(reason, nil), do: "Woo order-index #{reason}"
  defp default_message(reason, status), do: "Woo order-index #{reason} (HTTP #{status})"
end
