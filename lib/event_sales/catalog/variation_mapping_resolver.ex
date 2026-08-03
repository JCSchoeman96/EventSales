defmodule EventSales.Catalog.VariationMappingResolver do
  @moduledoc """
  Admin-only boundary for revoking a ready plan and resolving one reviewed
  exact variation exception.
  """

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog.ManualMappingCreator
  alias EventSales.Catalog.VariationMappingReview
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogSync

  @details "Manual variation mapping resolution started"

  @spec prepare(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, TickeraCatalogSyncRun.t()} | {:error, atom()}
  def prepare(run_id, dry_run_hash, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorize(actor),
         {:ok, review} <- VariationMappingReview.list(run_id, dry_run_hash, actor: actor),
         :ok <- require_ready(review.run_status) do
      TickeraCatalogSync.revoke_ready_dry_run(
        run_id,
        %{
          cancellation_reason_code: :mapping_resolution_started,
          cancellation_reason_details: @details
        },
        actor: actor
      )
    end
  end

  @spec resolve(
          Ecto.UUID.t(),
          String.t(),
          integer() | String.t(),
          integer() | String.t(),
          term(),
          keyword()
        ) :: ManualMappingCreator.result()
  def resolve(run_id, dry_run_hash, woo_product_id, woo_variation_id, params, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorize(actor),
         {:ok, product_id} <- positive_integer(woo_product_id, :invalid_woo_product_id),
         {:ok, variation_id} <-
           positive_integer(woo_variation_id, :invalid_woo_variation_id),
         :ok <- validate_params(params),
         {:ok, review} <- VariationMappingReview.list(run_id, dry_run_hash, actor: actor),
         :ok <- require_prepared_run(review),
         {:ok, row} <- find_row(review.rows, product_id, variation_id),
         :ok <- require_manual_action(row),
         {:ok, result} <-
           ManualMappingCreator.create(
             resolution_params(params, review, row),
             actor: actor,
             provenance: provenance(review, row)
           ) do
      {:ok, result}
    else
      {:error, :duplicate_mapping} ->
        duplicate_result(
          run_id,
          dry_run_hash,
          woo_product_id,
          woo_variation_id,
          actor
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize(actor) do
    if Policies.global_admin?(actor), do: :ok, else: {:error, :forbidden}
  end

  defp validate_params(params) when is_map(params), do: :ok
  defp validate_params(_params), do: {:error, :invalid_params}

  defp require_ready(:dry_run_ready), do: :ok
  defp require_ready(:cancelled), do: {:error, :already_cancelled}
  defp require_ready(_status), do: {:error, :run_not_revokeable}

  defp require_prepared_run(review) do
    case Ash.get(TickeraCatalogSyncRun, review.run_id, domain: Ingestion) do
      {:ok,
       %TickeraCatalogSyncRun{
         status: :cancelled,
         cancellation_reason_code: :mapping_resolution_started,
         dry_run_hash: hash
       }}
      when hash == review.dry_run_hash ->
        :ok

      {:ok, %TickeraCatalogSyncRun{}} ->
        {:error, :run_not_prepared}

      _other ->
        {:error, :stale_preview}
    end
  end

  defp find_row(rows, product_id, variation_id) do
    case Enum.find(
           rows,
           &(&1.woo_product_id == product_id and &1.woo_variation_id == variation_id)
         ) do
      nil -> {:error, :variation_not_reviewed}
      row -> {:ok, row}
    end
  end

  defp require_manual_action(%{
         classification: :manual_resolution_required,
         manual_action_allowed: true
       }),
       do: :ok

  defp require_manual_action(%{classification: :already_mapped_exact}),
    do: {:error, :already_mapped_exact}

  defp require_manual_action(%{classification: :stale_mapping_conflict}),
    do: {:error, :use_mapping_conflict_resolver}

  defp require_manual_action(_row), do: {:error, :manual_action_not_allowed}

  defp resolution_params(params, review, row) do
    params
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(
      ~w(event_id ticket_type_mode ticket_type_id ticket_type_name source_status reason)
    )
    |> Map.merge(%{
      "source_system_id" => review.source_system_id,
      "woo_product_id" => row.woo_product_id,
      "woo_variation_id" => row.woo_variation_id,
      "label" => row.source_label
    })
  end

  defp provenance(review, row) do
    %{
      catalog_sync_run_id: review.run_id,
      dry_run_hash: review.dry_run_hash,
      tickera_event_id: row.tickera_event_id,
      woo_product_id: row.woo_product_id,
      woo_variation_id: row.woo_variation_id,
      resolution_source: "variation_mapping_review"
    }
  end

  defp duplicate_result(run_id, dry_run_hash, product_id, variation_id, actor) do
    with {:ok, product_id} <- positive_integer(product_id, :invalid_woo_product_id),
         {:ok, variation_id} <- positive_integer(variation_id, :invalid_woo_variation_id),
         {:ok, review} <- VariationMappingReview.list(run_id, dry_run_hash, actor: actor),
         {:ok, %{classification: :already_mapped_exact}} <-
           find_row(review.rows, product_id, variation_id) do
      {:error, :already_mapped_exact}
    else
      _other -> {:error, :duplicate_mapping}
    end
  end

  defp positive_integer(value, _error) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, error) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, error}
    end
  end

  defp positive_integer(_value, error), do: {:error, error}
end
