defmodule EventSales.Ingestion.Security.WebhookSignature do
  @moduledoc """
  WooCommerce webhook HMAC-SHA256 (Base64) verification over exact raw body bytes.
  """

  @spec verify(iodata(), iodata(), String.t() | nil) ::
          :ok | {:error, :missing_signature | :invalid_signature}
  def verify(_raw_body, _secret, nil), do: {:error, :missing_signature}
  def verify(_raw_body, _secret, ""), do: {:error, :missing_signature}

  def verify(raw_body, secret, provided_signature) do
    expected = sign(raw_body, secret)

    if secure_compare?(expected, provided_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @spec sign(iodata(), iodata()) :: String.t()
  def sign(raw_body, secret) do
    :hmac
    |> :crypto.mac(:sha256, IO.iodata_to_binary(secret), IO.iodata_to_binary(raw_body))
    |> Base.encode64()
  end

  defp secure_compare?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare?(_, _), do: false
end
