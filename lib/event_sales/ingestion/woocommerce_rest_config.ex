defmodule EventSales.Ingestion.WooCommerceRestConfig do
  @moduledoc """
  Launch cutover guard for WooCommerce REST credential configuration.
  """

  alias EventSales.Ingestion.Clients.WooCommerceClient

  @spec configured?() :: boolean()
  def configured? do
    match?(:ok, validate_for_live_cutover())
  end

  @spec validate_for_live_cutover!() :: :ok
  def validate_for_live_cutover! do
    case validate_for_live_cutover() do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "WooCommerce REST configuration is not ready for live cutover: #{inspect(reason)}"
    end
  end

  @spec validate_for_live_cutover() :: :ok | {:error, term()}
  def validate_for_live_cutover do
    with :ok <- WooCommerceClient.validate_configuration(),
         :ok <- assert_max_concurrency_two() do
      :ok
    else
      {:error, %EventSales.Ingestion.Clients.WooCommerceError{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assert_max_concurrency_two do
    max_concurrency =
      :event_sales
      |> Application.get_env(:woocommerce_rest, [])
      |> Keyword.get(:max_concurrency)

    if max_concurrency == 2 do
      :ok
    else
      {:error, {:invalid_max_concurrency, max_concurrency}}
    end
  end
end
