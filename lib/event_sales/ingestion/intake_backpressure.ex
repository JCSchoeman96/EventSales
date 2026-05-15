defmodule EventSales.Ingestion.IntakeBackpressure do
  @moduledoc """
  Classifies webhook intake persist failures for flash-sale backpressure handling.

  Pool saturation errors may route to the optional Redis degraded-mode buffer.
  Constraint and other errors follow the normal intake error paths.
  """

  @type persist_error :: term()
  @type classification :: {:pool_saturated, persist_error()} | {:other, persist_error()}

  @doc """
  Returns true when the error indicates DB pool saturation (checkout/queue timeout).
  """
  @spec pool_saturated?(persist_error()) :: boolean()
  def pool_saturated?(error), do: match?({:pool_saturated, _}, classify_persist_error(error))

  @doc """
  Classifies a persist error as pool saturation or another failure class.
  """
  @spec classify_persist_error(persist_error()) :: classification()
  def classify_persist_error(error) do
    if pool_saturation_error?(error) do
      {:pool_saturated, error}
    else
      {:other, error}
    end
  end

  defp pool_saturation_error?(%DBConnection.ConnectionError{reason: reason})
       when reason in [:queue_timeout, :timeout],
       do: true

  defp pool_saturation_error?(%DBConnection.ConnectionError{message: message})
       when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "queue_timeout") or
      String.contains?(downcased, "queue time") or
      String.contains?(downcased, "not available") or
      String.contains?(downcased, "checkout")
  end

  defp pool_saturation_error?(_), do: false
end
