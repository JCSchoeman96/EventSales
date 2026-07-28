defmodule EventSales.Maintenance.LocalCatalogDryRun do
  @moduledoc """
  Runs the existing Tickera catalogue discovery and planning workflow locally
  without invoking Apply.
  """

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogSync

  @local_wordpress_url "http://localhost:10059"
  @local_operator_email "local-catalog-operator@eventsales.local"
  @scope %{"kind" => "wordpress_feed", "mode" => "full"}
  @poll_interval_ms 250
  @poll_attempts 240

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with :ok <- validate_local_runtime(),
         :ok <- validate_local_feed(),
         :ok <- validate_auto_apply_disabled(),
         {:ok, source} <- source_system(opts),
         {:ok, operator} <- resolve_operator(opts),
         {:ok, run, reused?} <- obtain_run(source.id, operator, opts),
         {:ok, ready} <- await_ready(run, opts),
         :ok <- validate_ready(ready),
         {:ok, result} <- build_result(ready, reused?, opts) do
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

  defp resolve_operator(opts) do
    case Keyword.get(opts, :operator) do
      %User{} = operator ->
        if Policies.global_admin?(operator),
          do: {:ok, operator},
          else: {:error, :local_operator_not_authorized}

      nil ->
        find_or_create_local_operator()

      _other ->
        {:error, :local_operator_not_authorized}
    end
  end

  defp find_or_create_local_operator do
    with {:ok, user} <- find_or_create_local_user(),
         {:ok, role} <- find_or_create_admin_role(),
         :ok <- ensure_role(user, role) do
      {:ok, user}
    end
  end

  defp find_or_create_local_user do
    query = Ash.Query.filter(User, email == ^@local_operator_email)

    case Ash.read_one(query, domain: Accounts) do
      {:ok, %User{} = user} ->
        {:ok, user}

      {:ok, nil} ->
        password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false) <> "Aa1!"

        Ash.create(
          User,
          %{
            email: @local_operator_email,
            name: "Local Catalogue Maintenance",
            password: password,
            password_confirmation: password
          },
          action: :register_with_password,
          domain: Accounts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_or_create_admin_role do
    query = Ash.Query.filter(Role, name == :admin)

    case Ash.read_one(query, domain: Accounts) do
      {:ok, %Role{} = role} ->
        {:ok, role}

      {:ok, nil} ->
        Ash.create(Role, %{name: :admin}, action: :create, domain: Accounts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_role(user, role) do
    query = Ash.Query.filter(UserRole, user_id == ^user.id and role_id == ^role.id)

    case Ash.read_one(query, domain: Accounts) do
      {:ok, %UserRole{}} ->
        :ok

      {:ok, nil} ->
        case Ash.create(
               UserRole,
               %{user_id: user.id, role_id: role.id},
               action: :create,
               domain: Accounts
             ) do
          {:ok, _user_role} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp obtain_run(source_system_id, operator, opts) do
    case active_run_for_source(source_system_id, operator, opts) do
      {:ok, nil} -> queue_or_recover(source_system_id, operator, opts)
      {:ok, run} -> classify_active_run(run, true)
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_run_for_source(source_system_id, operator, opts) do
    case Keyword.get(opts, :active_run_for_source) do
      callback when is_function(callback, 2) -> callback.(source_system_id, operator)
      nil -> TickeraCatalogSync.active_run_for_source(source_system_id, actor: operator)
    end
  end

  defp queue_or_recover(source_system_id, operator, opts) do
    case queue_dry_run(source_system_id, operator, opts) do
      {:ok, %{run: run}} ->
        {:ok, run, false}

      {:error, :catalog_sync_already_active} ->
        case active_run_for_source(source_system_id, operator, opts) do
          {:ok, nil} -> {:error, :active_run_not_found_after_queue_race}
          {:ok, run} -> classify_active_run(run, true)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp queue_dry_run(source_system_id, operator, opts) do
    case Keyword.get(opts, :queue_dry_run) do
      callback when is_function(callback, 2) ->
        callback.(source_system_id, operator)

      nil ->
        TickeraCatalogSync.queue_dry_run(
          %{source_system_id: source_system_id, scope: @scope},
          actor: operator
        )
    end
  end

  defp classify_active_run(%{status: status} = run, reused?)
       when status in [:queued, :discovering, :retry_scheduled, :dry_run_ready],
       do: {:ok, run, reused?}

  defp classify_active_run(%{status: :applying}, _reused?), do: {:error, :apply_in_progress}
  defp classify_active_run(%{status: :applied}, _reused?), do: {:error, :unexpected_apply_state}

  defp classify_active_run(%{status: status}, _reused?),
    do: {:error, {:unexpected_run_state, status}}

  defp await_ready(%{status: :dry_run_ready, id: run_id}, _opts), do: load_run(run_id)
  defp await_ready(%{status: :applying}, _opts), do: {:error, :apply_in_progress}
  defp await_ready(%{status: :applied}, _opts), do: {:error, :unexpected_apply_state}

  defp await_ready(%{status: status, id: run_id}, opts)
       when status in [:queued, :discovering, :retry_scheduled] do
    case Keyword.get(opts, :poll_run) do
      callback when is_function(callback, 1) -> callback.(run_id)
      nil -> poll_run(run_id, @poll_attempts)
    end
  end

  defp poll_run(_run_id, 0), do: {:error, :dry_run_poll_timeout}

  defp poll_run(run_id, attempts_left) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <- load_run(run_id) do
      case run.status do
        :dry_run_ready ->
          {:ok, run}

        status when status in [:queued, :discovering, :retry_scheduled] ->
          Process.sleep(@poll_interval_ms)
          poll_run(run_id, attempts_left - 1)

        :applying ->
          {:error, :apply_in_progress}

        :applied ->
          {:error, :unexpected_apply_state}

        status ->
          {:error, {:dry_run_not_ready, status, run.last_error}}
      end
    else
      {:ok, nil} -> {:error, :run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_run(run_id), do: Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion)

  defp validate_ready(%TickeraCatalogSyncRun{status: :dry_run_ready}), do: :ok

  defp validate_ready(%TickeraCatalogSyncRun{status: status, last_error: last_error}),
    do: {:error, {:dry_run_not_ready, status, last_error}}

  defp validate_ready(nil), do: {:error, :run_not_found}

  defp build_result(run, reused?, opts) do
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
      findings = findings(run.id)

      {:ok,
       %{
         run_id: run.id,
         status: run.status,
         reused_existing_run: reused?,
         dry_run_hash: run.dry_run_hash,
         summary: run.summary,
         finding_count: length(findings),
         finding_summary: finding_summary(findings),
         finding_codes: findings |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort(),
         variation_ids: variation_ids,
         expected_variation_ids_present?: true
       }}
    else
      {:error, {:missing_expected_variation_ids, missing_ids, run.id}}
    end
  end

  defp findings(run_id) do
    TickeraCatalogSyncFinding
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
  end

  defp finding_summary(findings) do
    counts = Enum.frequencies_by(findings, & &1.severity)

    %{
      total: length(findings),
      blocking: Map.get(counts, :blocking, 0),
      warning: Map.get(counts, :warning, 0),
      info: Map.get(counts, :info, 0)
    }
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
