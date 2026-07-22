defmodule EventSales.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_validate_live_cutover!()

    children =
      [
        EventSalesWeb.Telemetry,
        repo_child(),
        database_readiness_child(),
        EventSales.Ingestion.RestRateLimiter,
        EventSales.Ingestion.RestCircuitBreaker,
        EventSales.Catalog.ProductMetadataCache,
        oban_child(),
        redis_child(),
        rate_limit_redis_child(),
        {DNSCluster, query: Application.get_env(:event_sales, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: EventSales.PubSub},
        analytics_redis_child(),
        EventSales.Analytics.HotStateAggregator,
        # Start a worker by calling: EventSales.Worker.start_link(arg)
        # {EventSales.Worker, arg},
        # Start to serve requests, typically the last entry
        EventSalesWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EventSales.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EventSalesWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp repo_child do
    if Application.get_env(:event_sales, :start_repo, true) do
      EventSales.Repo
    end
  end

  defp database_readiness_child do
    if Application.get_env(:event_sales, :start_database_readiness, true) do
      EventSales.Health.DatabaseReadiness
    end
  end

  defp oban_child do
    {Oban, Application.fetch_env!(:event_sales, Oban)}
  end

  defp redis_child do
    cfg = Application.get_env(:event_sales, :redis_webhook_buffer, [])

    with true <- Keyword.get(cfg, :enabled, false),
         true <- Keyword.get(cfg, :durability_accepted, false),
         url when is_binary(url) and url != "" <- Keyword.get(cfg, :redis_url) do
      Supervisor.child_spec(
        {Redix, {url, name: EventSales.Ingestion.RedisWebhookBuffer.redix_name()}},
        id: :event_sales_webhook_buffer_redix
      )
    else
      _ -> nil
    end
  end

  defp analytics_redis_child do
    cfg = Application.get_env(:event_sales, :hot_state_aggregator, [])

    with true <- Keyword.get(cfg, :redis_enabled, false),
         url when is_binary(url) and url != "" <- Keyword.get(cfg, :redis_url) do
      Supervisor.child_spec(
        {Redix, {url, name: EventSales.Analytics.SnapshotStore.RedixAdapter.redix_name()}},
        id: :event_sales_analytics_redis
      )
    else
      _ -> nil
    end
  end

  defp rate_limit_redis_child do
    cfg = Application.get_env(:event_sales, :webhook_intake_rate_limit, [])
    buffer_cfg = Application.get_env(:event_sales, :redis_webhook_buffer, [])

    with true <- Keyword.get(cfg, :enabled, false),
         adapter when adapter == EventSales.Ingestion.RedisRateLimiter.RedixAdapter <-
           Keyword.get(cfg, :adapter),
         rate_limit_url when is_binary(rate_limit_url) and rate_limit_url != "" <-
           Keyword.get(cfg, :redis_url),
         false <- shared_webhook_buffer_redis?(buffer_cfg, rate_limit_url) do
      Supervisor.child_spec(
        {Redix, {rate_limit_url, name: EventSales.Ingestion.RedisRateLimiter.redix_name()}},
        id: :event_sales_rate_limit_redix
      )
    else
      _ -> nil
    end
  end

  defp shared_webhook_buffer_redis?(buffer_cfg, rate_limit_url) do
    Keyword.get(buffer_cfg, :enabled, false) &&
      Keyword.get(buffer_cfg, :durability_accepted, false) &&
      Keyword.get(buffer_cfg, :redis_url) == rate_limit_url
  end

  defp maybe_validate_live_cutover! do
    if System.get_env("EVENTSALES_LIVE_CUTOVER_ENABLED") in ~w(true 1) do
      EventSales.Ingestion.WooCommerceRestConfig.validate_for_live_cutover!()
    end

    :ok
  end
end
