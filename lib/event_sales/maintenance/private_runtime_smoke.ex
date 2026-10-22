defmodule EventSales.Maintenance.PrivateRuntimeSmoke do
  @moduledoc """
  Runs bounded, secret-safe checks for the private production runtime.

  This module observes the already-started application and its configured
  adapters. It does not start the application or run migrations.
  """

  alias EventSales.Analytics.{CacheKeys, SnapshotCodec, SnapshotStore.RedixAdapter}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Health.DatabaseReadiness
  alias EventSales.Ingestion.RedisRateLimiter
  alias EventSales.Ingestion.RedisRateLimiter.RedixAdapter, as: RateLimitRedixAdapter
  alias EventSales.Maintenance.ObanTopologySmokeWorker
  alias EventSales.Repo
  alias Oban.Job

  defmodule Error do
    defexception [:message]
  end

  @forbidden_env_keys [
    "DIRECT_DATABASE_URL",
    "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL",
    "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD",
    "EVENTSALES_BOOTSTRAP_ADMIN_NAME",
    "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD",
    "EVENTSALES_BOOTSTRAP_SOURCE_NAME",
    "EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL"
  ]

  @runtime_database_host "pgbouncer"
  @runtime_database_port 6432
  @runtime_database_name "event_sales_prod"
  @runtime_redis_namespace "eventsales:prod"
  @rate_limit_key_prefix "eventsales:prod:webhook_rate_limit:v1"
  @prepared_query_name "event_sales_private_runtime_smoke_parameterized_v1"
  @snapshot_ttl_ms 60_000

  @safe_config_keys MapSet.new([
                      :database_host,
                      :database_port,
                      :database_name,
                      :hot_state_redis_enabled?,
                      :timeout_ms,
                      :poll_interval_ms
                    ])

  @spec config!(map() | keyword()) :: map()
  def config!(env \\ System.get_env()) do
    env = normalize_env(env)
    reject_forbidden_environment!(env)
    database = database_target!(Map.get(env, "DATABASE_URL"))
    runtime = runtime_contract!()

    %{
      database_host: database.host,
      database_port: database.port,
      database_name: database.database,
      hot_state_redis_enabled?: runtime.hot_state_redis_enabled?,
      timeout_ms: positive_integer_env(env, "EVENTSALES_SMOKE_TIMEOUT_MS", 60_000),
      poll_interval_ms: positive_integer_env(env, "EVENTSALES_SMOKE_POLL_INTERVAL_MS", 500)
    }
  end

  @spec run!(keyword()) :: :ok
  def run!(opts \\ []) do
    config = config!(Keyword.get(opts, :env, System.get_env()))
    checks = Keyword.get(opts, :checks, default_checks())
    output = Keyword.get(opts, :output, &IO.puts/1)

    Enum.each(checks, fn {label, check} ->
      result =
        try do
          check.(config)
        rescue
          _error -> :error
        catch
          _kind, _reason -> :error
        end

      case result do
        :ok -> output.("private runtime smoke: #{label} passed")
        _other -> raise Error, "private runtime smoke check failed: #{label}"
      end
    end)

    output.("private runtime smoke: complete")
    :ok
  end

  defp default_checks do
    [
      {"application", &check_application/1},
      {"migrations", &check_migrations/1},
      {"database identity", &check_database_identity/1},
      {"prepared queries", &check_prepared_queries/1},
      {"Ash read", &check_ash_read/1},
      {"Oban success and retry", &check_oban_jobs/1},
      {"Oban notifier", &check_oban_notifier/1},
      {"Redis rate limiter", &check_rate_limiter/1},
      {"hot-state Redis snapshots", &check_hot_state_snapshots/1},
      {"database readiness", &check_readiness/1},
      {"webhook buffer disabled", &check_webhook_buffer/1},
      {"secret-safe evidence", &check_safe_config/1}
    ]
  end

  defp check_application(_config) do
    if Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
         app == :event_sales
       end) do
      :ok
    else
      :error
    end
  end

  defp check_migrations(_config) do
    case Enum.reject(Ecto.Migrator.migrations(Repo), &match?({:up, _, _}, &1)) do
      [] -> :ok
      _pending -> :error
    end
  end

  defp check_database_identity(_config) do
    case Repo.query("SELECT current_user, current_database(), inet_server_port()") do
      {:ok, %{rows: [["eventsales_runtime", "event_sales_prod", 5432]]}} -> :ok
      _other -> :error
    end
  end

  defp check_prepared_queries(_config) do
    Enum.reduce_while([137, 211], :ok, fn expected, :ok ->
      result =
        Repo.transaction(fn ->
          Repo.query!("SELECT $1::integer", [expected], cache_statement: @prepared_query_name)
        end)

      case result do
        {:ok, %{rows: [[^expected]]}} -> {:cont, :ok}
        _other -> {:halt, :error}
      end
    end)
  end

  defp check_ash_read(_config) do
    query = SourceSystem |> Ash.Query.limit(1)

    case Ash.read(query, domain: Catalog) do
      {:ok, _source_systems} -> :ok
      _other -> :error
    end
  end

  defp check_oban_jobs(config) do
    run_id = "private-runtime-#{System.unique_integer([:positive])}"
    success = insert_smoke_job!("success", run_id)
    retry = insert_smoke_job!("fail_once", run_id)
    success = wait_for_job(success.id, config.timeout_ms, config.poll_interval_ms)
    retry = wait_for_job(retry.id, config.timeout_ms, config.poll_interval_ms)

    case {success, retry} do
      {%Job{state: "completed"}, %Job{state: "completed", attempt: attempt, errors: errors}}
      when attempt >= 2 and is_list(errors) and errors != [] ->
        :ok

      _other ->
        :error
    end
  end

  defp check_oban_notifier(_config) do
    notifier =
      :event_sales
      |> Application.get_env(Oban, [])
      |> Keyword.get(:notifier)

    if notifier == Oban.Notifiers.PG, do: :ok, else: :error
  end

  defp check_rate_limiter(_config) do
    case RedisRateLimiter.allow?("private-runtime-smoke-#{Ecto.UUID.generate()}") do
      :ok -> :ok
      _other -> :error
    end
  end

  defp check_hot_state_snapshots(%{hot_state_redis_enabled?: false}), do: :ok

  defp check_hot_state_snapshots(%{hot_state_redis_enabled?: true}) do
    event_id = Ecto.UUID.generate()
    key = CacheKeys.redis_event_snapshot(event_id)

    summary = %{
      total_sold: 1,
      total_revenue: Decimal.new("1.00"),
      today_sold: 1,
      today_revenue: Decimal.new("1.00"),
      status_breakdown: %{completed: 1},
      updated_at: DateTime.utc_now()
    }

    with :ok <- RedixAdapter.put(key, summary, ttl_ms: @snapshot_ttl_ms),
         {:ok, encoded} when is_binary(encoded) <-
           Redix.command(RedixAdapter.redix_name(), ["GET", key]),
         {:ok, restored} <- SnapshotCodec.decode(encoded),
         true <- restored == summary do
      :ok
    else
      _other -> :error
    end
  end

  defp check_readiness(config) do
    case Process.whereis(DatabaseReadiness) do
      nil ->
        :error

      _pid ->
        :ok = DatabaseReadiness.probe_now()
        wait_for_readiness(config.timeout_ms, config.poll_interval_ms)
    end
  end

  defp check_webhook_buffer(_config) do
    buffer = Application.get_env(:event_sales, :redis_webhook_buffer, [])

    if Keyword.get(buffer, :enabled) == false and
         Keyword.get(buffer, :durability_accepted) == false do
      :ok
    else
      :error
    end
  end

  defp check_safe_config(config) do
    if config |> Map.keys() |> MapSet.new() |> MapSet.equal?(@safe_config_keys) do
      :ok
    else
      :error
    end
  end

  defp insert_smoke_job!(mode, run_id) do
    %{mode: mode, run_id: run_id}
    |> ObanTopologySmokeWorker.new()
    |> Oban.insert!()
  end

  defp wait_for_job(job_id, timeout_ms, poll_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_job(job_id, deadline, poll_ms)
  end

  defp do_wait_for_job(job_id, deadline, poll_ms) do
    case Repo.get(Job, job_id) do
      %Job{state: "completed"} = job ->
        job

      %Job{} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :error
        else
          Process.sleep(poll_ms)
          do_wait_for_job(job_id, deadline, poll_ms)
        end

      nil ->
        :error
    end
  end

  defp wait_for_readiness(timeout_ms, poll_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_readiness(deadline, poll_ms)
  end

  defp do_wait_for_readiness(deadline, poll_ms) do
    case DatabaseReadiness.status() do
      :ready ->
        :ok

      :not_ready ->
        if System.monotonic_time(:millisecond) >= deadline do
          :error
        else
          Process.sleep(poll_ms)
          do_wait_for_readiness(deadline, poll_ms)
        end
    end
  end

  defp runtime_contract! do
    require_redis_namespace!()
    require_oban_notifier!()
    require_rate_limiter!()
    require_webhook_buffer_disabled!()

    %{hot_state_redis_enabled?: require_hot_state_contract!()}
  end

  defp require_redis_namespace! do
    unless Application.get_env(:event_sales, :redis_namespace) == @runtime_redis_namespace,
      do: raise(Error, "private runtime requires the D1 Redis namespace")
  end

  defp require_oban_notifier! do
    notifier = :event_sales |> Application.get_env(Oban, []) |> Keyword.get(:notifier)

    unless notifier == Oban.Notifiers.PG,
      do: raise(Error, "private runtime requires the Oban PG notifier")
  end

  defp require_rate_limiter! do
    rate_limit_config = Application.get_env(:event_sales, :webhook_intake_rate_limit, [])

    unless Keyword.get(rate_limit_config, :enabled) == true and
             Keyword.get(rate_limit_config, :adapter) == RateLimitRedixAdapter and
             Keyword.get(rate_limit_config, :key_prefix) == @rate_limit_key_prefix do
      raise Error, "private runtime requires the production Redis rate limiter"
    end
  end

  defp require_webhook_buffer_disabled! do
    buffer_config = Application.get_env(:event_sales, :redis_webhook_buffer, [])

    unless Keyword.get(buffer_config, :enabled) == false and
             Keyword.get(buffer_config, :durability_accepted) == false do
      raise Error, "private runtime requires webhook buffering to remain disabled"
    end
  end

  defp require_hot_state_contract! do
    hot_state_config = Application.get_env(:event_sales, :hot_state_aggregator, [])
    redis_enabled? = Keyword.get(hot_state_config, :redis_enabled)
    snapshot_adapter = Keyword.get(hot_state_config, :snapshot_adapter)

    valid? =
      is_boolean(redis_enabled?) and
        if redis_enabled? do
          snapshot_adapter == RedixAdapter
        else
          snapshot_adapter == EventSales.Analytics.SnapshotStore.NoopAdapter
        end

    unless valid?,
      do: raise(Error, "private runtime hot-state Redis configuration is invalid")

    redis_enabled?
  end

  defp database_target!(database_url) when is_binary(database_url) do
    case URI.new(database_url) do
      {:ok, uri} ->
        if uri.scheme in ["ecto", "postgres", "postgresql"] and
             uri.host == @runtime_database_host and uri.port == @runtime_database_port and
             uri.path == "/#{@runtime_database_name}" do
          %{host: uri.host, port: uri.port, database: @runtime_database_name}
        else
          invalid_database_target!()
        end

      {:error, _reason} ->
        invalid_database_target!()
    end
  end

  defp database_target!(_database_url),
    do: invalid_database_target!()

  defp invalid_database_target!,
    do: raise(Error, "DATABASE_URL must target the D1 PgBouncer database")

  defp reject_forbidden_environment!(env) do
    case Enum.find(@forbidden_env_keys, &Map.has_key?(env, &1)) do
      nil -> :ok
      key -> raise Error, "#{key} is not permitted in the private runtime"
    end
  end

  defp positive_integer_env(env, key, default) do
    case Map.get(env, key) do
      nil ->
        default

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _other -> raise Error, "#{key} must be a positive integer"
        end

      _other ->
        raise Error, "#{key} must be a positive integer"
    end
  end

  defp normalize_env(env) do
    env
    |> Map.new()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end
end
