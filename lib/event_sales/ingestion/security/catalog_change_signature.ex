defmodule EventSales.Ingestion.Security.CatalogChangeSignature do
  @moduledoc "HMAC-SHA256 verification for catalogue change signals."

  @version "2026-07-20.v1"
  @window 300

  def sign(path, timestamp, raw_body, secret)
      when is_binary(path) and is_integer(timestamp) and is_binary(raw_body) and is_binary(secret) do
    signature =
      @version
      |> canonical(path, timestamp, raw_body)
      |> then(&:crypto.mac(:hmac, :sha256, secret, &1))
      |> Base.encode16(case: :lower)

    "v1=" <> signature
  end

  def verify(path, timestamp, raw_body, provided, secret) do
    expected = sign(path, timestamp, raw_body, secret)

    if secure_compare(expected, provided),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  def verify_request(path, timestamp, raw_body, provided, keys, key_id, opts \\ [])

  def verify_request(path, timestamp, raw_body, provided, keys, key_id, opts)
      when is_binary(timestamp) and is_binary(provided) and is_binary(key_id) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    window = Keyword.get(opts, :replay_window_seconds, @window)

    case Integer.parse(timestamp) do
      {parsed, ""} -> verify_parsed(path, parsed, raw_body, provided, keys, key_id, now, window)
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  def verify_request(_path, _timestamp, _raw_body, _provided, _keys, _key_id, _opts),
    do: {:error, :invalid_signature}

  defp verify_parsed(path, timestamp, raw_body, provided, keys, key_id, now, window) do
    with true <- abs(now - timestamp) <= window,
         {:ok, secret} <- Map.fetch(keys, key_id),
         :ok <- verify(path, timestamp, raw_body, provided, secret) do
      :ok
    else
      false -> {:error, :stale_timestamp}
      :error -> {:error, :unknown_key_id}
      {:error, _reason} = error -> error
    end
  end

  defp canonical(version, path, timestamp, raw_body) do
    body_hash = :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)
    Enum.join([version, "POST", path, Integer.to_string(timestamp), body_hash], "\n")
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp secure_compare(_, _), do: false
end
