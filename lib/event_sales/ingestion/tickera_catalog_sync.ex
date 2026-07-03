defmodule EventSales.Ingestion.TickeraCatalogSync do
  @moduledoc """
  Admin facade for Tickera catalog sync dry-run and apply.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}

  @default_limit 50

  def queue_dry_run(attrs, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, source_system_id} <- fetch_required(attrs, :source_system_id),
         {:ok, scope} <- fetch_scope(attrs),
         {:ok, run} <- create_run(source_system_id, scope, opts),
         {:ok, job} <- enqueue_discovery(run, opts) do
      {:ok, %{run: run, job: job}}
    end
  end

  def queue_apply(run_id, dry_run_hash, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         {:ok, job} <- enqueue_apply(run, dry_run_hash, opts) do
      {:ok, %{run: run, job: job}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, sanitize_error(reason)}
    end
  end

  def list_runs(opts \\ []) do
    with :ok <- authorize_admin(opts) do
      TickeraCatalogSyncRun
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, @default_limit))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_run_preview(run_id, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %{run: run, preview: run.plan_snapshot || %{}}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, sanitize_error(reason)}
    end
  end

  def list_source_systems(opts \\ []) do
    with :ok <- authorize_admin(opts) do
      SourceSystem
      |> Ash.Query.filter(kind == :woocommerce and active == true)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read(domain: Catalog)
    end
  end

  defp create_run(source_system_id, scope, opts) do
    actor = Keyword.get(opts, :actor)

    Ash.create(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source_system_id,
        requested_by_user_id: actor && actor.id,
        scope: json_safe(scope),
        status: :queued
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp enqueue_discovery(run, opts) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    case %{"run_id" => run.id}
         |> DiscoverTickeraCatalogWorker.new()
         |> oban_insert.() do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp enqueue_apply(run, dry_run_hash, opts) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    case %{"run_id" => run.id, "dry_run_hash" => dry_run_hash}
         |> ApplyTickeraCatalogWorker.new()
         |> oban_insert.() do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, key}
    end
  end

  defp fetch_scope(attrs) do
    case Map.get(attrs, :scope) || Map.get(attrs, "scope") do
      %{} = scope -> {:ok, scope}
      _value -> {:error, :invalid_scope}
    end
  end

  defp sanitize_error(:forbidden), do: :forbidden
  defp sanitize_error({:enqueue_failed, _reason}), do: :enqueue_failed
  defp sanitize_error(_reason), do: :failed

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value), do: value
end
