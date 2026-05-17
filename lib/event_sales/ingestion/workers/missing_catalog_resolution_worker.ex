defmodule EventSales.Ingestion.Workers.MissingCatalogResolutionWorker do
  @moduledoc """
  Recovers order items that arrived before catalog metadata or mapping existed.

  This worker is the only Slice 8.5 WooCommerce REST caller. It fetches product
  metadata through the configured client boundary, stores bounded informational
  metadata, and then retries local mapping through `MissingCatalogResolver`.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:source_system_id, :woo_product_id, :woo_variation_id],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Catalog.{MissingCatalogResolver, ProductMetadataCache}
  alias EventSales.Ingestion.Clients.{WooCommerceClient, WooCommerceError}
  alias EventSales.Telemetry

  @retryable_reasons MapSet.new([
                       :rate_limited,
                       :server_error,
                       :timeout,
                       :transport_error,
                       :queue_timeout,
                       :circuit_open
                     ])
  @discard_reasons MapSet.new([:misconfigured, :unauthorized, :forbidden, :invalid_request])

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case parse_args(args) do
      {:ok, recovery} ->
        recover(recovery)

      :error ->
        emit_exception(:discarded, :invalid_args)
        :discard
    end
  end

  defp recover(recovery) do
    emit_start()

    recovery
    |> ensure_metadata_cached()
    |> case do
      :ok ->
        recovery
        |> run_resolver()
        |> emit_stop_result()

      {:discard, reason} ->
        emit_exception(:discarded, reason)
        :discard

      {:error, reason} ->
        emit_exception(:retryable_error, reason)
        {:error, reason}
    end
  end

  defp ensure_metadata_cached(%{
         source_system_id: source_system_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id
       }) do
    case ProductMetadataCache.get(source_system_id, woo_product_id, woo_variation_id) do
      {:ok, _metadata} ->
        :ok

      :miss ->
        fetch_and_cache_metadata(source_system_id, woo_product_id, woo_variation_id)
    end
  end

  defp fetch_and_cache_metadata(source_system_id, woo_product_id, woo_variation_id) do
    case client().fetch_product(woo_product_id) do
      {:ok, product} ->
        product
        |> metadata_from_product(source_system_id, woo_product_id, woo_variation_id)
        |> ProductMetadataCache.put()

      {:error, %WooCommerceError{reason: :not_found}} ->
        :ok

      {:error, %WooCommerceError{reason: reason}} ->
        classify_error(reason)
    end
  end

  defp run_resolver(%{
         source_system_id: source_system_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id
       }) do
    MissingCatalogResolver.recover_product(source_system_id, woo_product_id, woo_variation_id)
  end

  defp emit_stop_result({:ok, result}) do
    Telemetry.emit(Telemetry.missing_catalog_recovery_stop(), %{count: 1}, %{
      source: :woocommerce,
      result: result_tag(result)
    })

    :ok
  end

  defp emit_stop_result({:error, reason}) do
    emit_exception(:retryable_error, reason)
    {:error, reason}
  end

  defp metadata_from_product(product, source_system_id, woo_product_id, woo_variation_id) do
    %{
      source_system_id: source_system_id,
      woo_product_id: woo_product_id,
      woo_variation_id: woo_variation_id,
      name: Map.get(product, "name") || Map.get(product, :name),
      product_type: Map.get(product, "type") || Map.get(product, :type),
      status: Map.get(product, "status") || Map.get(product, :status)
    }
  end

  defp classify_error(reason) do
    cond do
      MapSet.member?(@retryable_reasons, reason) -> {:error, reason}
      MapSet.member?(@discard_reasons, reason) -> {:discard, reason}
      true -> {:error, reason}
    end
  end

  defp result_tag(%{mapped: mapped}) when mapped > 0, do: :mapped

  defp result_tag(%{marked_unmapped: marked_unmapped}) when marked_unmapped > 0,
    do: :marked_unmapped

  defp result_tag(_result), do: :unchanged

  defp parse_args(%{
         "source_system_id" => source_system_id,
         "woo_product_id" => woo_product_id,
         "woo_variation_id" => woo_variation_id
       }) do
    with true <- is_binary(source_system_id),
         {:ok, woo_product_id} <- normalize_positive_integer(woo_product_id),
         {:ok, woo_variation_id} <- normalize_nullable_positive_integer(woo_variation_id) do
      {:ok,
       %{
         source_system_id: source_system_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id
       }}
    else
      _ -> :error
    end
  end

  defp parse_args(_args), do: :error

  defp normalize_nullable_positive_integer(nil), do: {:ok, nil}
  defp normalize_nullable_positive_integer(value), do: normalize_positive_integer(value)

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp normalize_positive_integer(_value), do: :error

  defp emit_start do
    Telemetry.emit(Telemetry.missing_catalog_recovery_start(), %{count: 1}, %{
      source: :woocommerce
    })
  end

  defp emit_exception(result, reason) do
    Telemetry.emit(Telemetry.missing_catalog_recovery_exception(), %{count: 1}, %{
      source: :woocommerce,
      result: result,
      reason: reason
    })
  end

  defp client do
    Application.get_env(:event_sales, :woocommerce_client, WooCommerceClient)
  end
end
