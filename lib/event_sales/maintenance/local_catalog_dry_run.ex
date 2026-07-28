defmodule EventSales.Maintenance.LocalCatalogDryRun do
  @moduledoc """
  Runs the existing Tickera catalogue discovery and planning workflow locally
  without invoking Apply.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker

  @local_wordpress_url "http://localhost:10059"
  @scope %{"kind" => "wordpress_feed", "mode" => "full"}

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with :ok <- validate_local_runtime(),
         :ok <- validate_local_feed(),
         :ok <- validate_auto_apply_disabled(),
         {:ok, source} <- source_system(opts),
         {:ok, run} <- create_run(source.id),
         :ok <- perform_discovery(run.id),
         {:ok, ready} <- Ash.get(TickeraCatalogSyncRun, run.id, domain: Ingestion),
         :ok <- validate_ready(ready),
         {:ok, result} <- build_result(ready, opts) do
      {:ok, result}
    end
  end

  defp validate_local_runtime do
    if Application.get_env(:event_sales, :env, :dev) in [:dev, :test],
      do: :ok,
      else: {:error, :not_local_runtime}
  end

  defp validate_local_feed do
    base_url =
      :event_sales
      |> Application.get_env(:tickera_catalog_feed, [])
      |> Keyword.get(:base_url)

    if base_url == @local_wordpress_url,
      do: :ok,
      else: {:error, :non_local_catalog_feed}
  end

  defp validate_auto_apply_disabled do
    hard_enabled? =
      :event_sales
      |> Application.get_env(:catalog_auto_apply, [])
      |> Keyword.get(:hard_enabled, false)

    env_enabled? = System.get_env("CATALOG_AUTO_APPLY_HARD_ENABLED") in ~w(true 1)

    if hard_enabled? or env_enabled?,
      do: {:error, :catalog_auto_apply_enabled},
      else: :ok
  end

  defp source_system(opts) do
    case Keyword.get(opts, :source_system_id) do
      id when is_binary(id) -> fetch_source(id)
      _other -> find_or_create_local_source()
    end
  end

  defp fetch_source(id) do
    case Ash.get(SourceSystem, id, domain: Catalog) do
      {:ok, %SourceSystem{} = source} -> validate_source(source)
      {:ok, nil} -> {:error, :source_system_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_or_create_local_source do
    query =
      SourceSystem
      |> Ash.Query.filter(
        kind == :woocommerce and base_url == ^@local_wordpress_url and active == true
      )

    case Ash.read_one(query, domain: Catalog) do
      {:ok, %SourceSystem{} = source} ->
        validate_source(source)

      {:ok, nil} ->
        Ash.create(
          SourceSystem,
          %{
            name: "Local WordPress",
            kind: :woocommerce,
            base_url: @local_wordpress_url,
            active: true,
            catalog_auto_apply_mode: :disabled,
            catalog_auto_apply_allowlisted: false
          },
          action: :create,
          domain: Catalog
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_source(
         %SourceSystem{
           kind: :woocommerce,
           base_url: @local_wordpress_url,
           active: true,
           catalog_auto_apply_mode: mode,
           catalog_auto_apply_allowlisted: false
         } = source
       )
       when mode in [:disabled, :inherit],
       do: {:ok, source}

  defp validate_source(_source), do: {:error, :unsafe_source_system}

  defp create_run(source_system_id) do
    Ash.create(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source_system_id,
        scope: @scope,
        origin: :legacy_unknown
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp perform_discovery(run_id) do
    DiscoverTickeraCatalogWorker.perform(%Oban.Job{
      args: %{"run_id" => run_id},
      attempt: 1,
      max_attempts: 1
    })
  end

  defp validate_ready(%TickeraCatalogSyncRun{status: :dry_run_ready}), do: :ok

  defp validate_ready(%TickeraCatalogSyncRun{status: status, last_error: last_error}),
    do: {:error, {:dry_run_not_ready, status, last_error}}

  defp validate_ready(nil), do: {:error, :run_not_found}

  defp build_result(run, opts) do
    variation_ids =
      run.plan_snapshot
      |> collect_variation_ids()
      |> Enum.uniq()
      |> Enum.sort()

    expected_ids =
      opts
      |> Keyword.get(:expected_variation_ids, [])
      |> Enum.uniq()
      |> Enum.sort()

    missing_ids = expected_ids -- variation_ids

    if missing_ids == [] do
      {:ok,
       %{
         run_id: run.id,
         status: run.status,
         dry_run_hash: run.dry_run_hash,
         summary: run.summary,
         finding_count: finding_count(run.id),
         variation_ids: variation_ids,
         expected_variation_ids_present?: true
       }}
    else
      {:error, {:missing_expected_variation_ids, missing_ids, run.id}}
    end
  end

  defp finding_count(run_id) do
    TickeraCatalogSyncFinding
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
    |> length()
  end

  defp collect_variation_ids(value) when is_list(value),
    do: Enum.flat_map(value, &collect_variation_ids/1)

  defp collect_variation_ids(%{} = value) do
    direct =
      value
      |> Enum.filter(fn {key, variation_id} ->
        to_string(key) in ["woo_variation_id", "external_variation_id"] and
          is_integer(variation_id) and variation_id > 0
      end)
      |> Enum.map(&elem(&1, 1))

    direct ++ Enum.flat_map(Map.values(value), &collect_variation_ids/1)
  end

  defp collect_variation_ids(_value), do: []
end
