defmodule EventSales.Ingestion.Security.LowCardinalityKey do
  @moduledoc """
  Derives stable, low-cardinality identifiers for rate limiting and telemetry.

  Never returns raw IPs, tokens, signatures, or PII.
  """

  @spec hash_term(term()) :: String.t()
  def hash_term(term) do
    term
    |> :erlang.term_to_binary()
    |> hash_binary()
  end

  @spec hash_binary(binary()) :: String.t()
  def hash_binary(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  @spec hash_remote_ip(term()) :: String.t()
  def hash_remote_ip(remote_ip) do
    remote_ip
    |> normalize_ip()
    |> hash_binary()
  end

  @spec token_presence(atom()) :: :present | :missing
  def token_presence(:present), do: :present
  def token_presence(:missing), do: :missing

  @spec token_presence_from_path_token(term()) :: :present | :missing
  def token_presence_from_path_token(token) when is_binary(token) and token != "",
    do: :present

  def token_presence_from_path_token(_), do: :missing

  defp normalize_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp normalize_ip(ip) when is_binary(ip), do: ip
  defp normalize_ip(ip), do: to_string(ip)
end
