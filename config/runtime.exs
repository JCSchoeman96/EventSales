import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/event_sales start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :event_sales, EventSalesWeb.Endpoint, server: true
end

direct_database_url = System.get_env("DIRECT_DATABASE_URL")

config :event_sales,
  direct_database_url: direct_database_url,
  business_timezone: System.get_env("EVENTSALES_BUSINESS_TIMEZONE", "Africa/Johannesburg"),
  default_currency: System.get_env("EVENTSALES_DEFAULT_CURRENCY", "ZAR")

config :event_sales, EventSalesWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  config :event_sales, :woocommerce_rest,
    base_url: System.get_env("WOOCOMMERCE_REST_BASE_URL"),
    consumer_key: System.get_env("WOOCOMMERCE_CONSUMER_KEY"),
    consumer_secret: System.get_env("WOOCOMMERCE_CONSUMER_SECRET"),
    timeout_ms: String.to_integer(System.get_env("WOOCOMMERCE_REST_TIMEOUT_MS", "5000")),
    queue_timeout_ms:
      String.to_integer(System.get_env("WOOCOMMERCE_REST_QUEUE_TIMEOUT_MS", "5000")),
    per_page: String.to_integer(System.get_env("WOOCOMMERCE_REST_PER_PAGE", "100")),
    max_pages: String.to_integer(System.get_env("WOOCOMMERCE_REST_MAX_PAGES", "50")),
    max_concurrency: 2,
    transport: EventSales.Ingestion.Clients.HttpcTransport

  config :event_sales, :tickera_api,
    default_site_url: System.get_env("TICKERA_DEFAULT_SITE_URL", "https://voelgoed.co.za"),
    timeout_ms: String.to_integer(System.get_env("TICKERA_TIMEOUT_MS", "30000")),
    connect_timeout_ms: String.to_integer(System.get_env("TICKERA_CONNECT_TIMEOUT_MS", "5000")),
    receive_timeout_ms: String.to_integer(System.get_env("TICKERA_RECEIVE_TIMEOUT_MS", "30000")),
    per_page: String.to_integer(System.get_env("TICKERA_PER_PAGE", "50")),
    max_pages: String.to_integer(System.get_env("TICKERA_MAX_PAGES", "200")),
    page_delay_ms: String.to_integer(System.get_env("TICKERA_PAGE_DELAY_MS", "100")),
    transport: EventSales.Ingestion.Clients.HttpcTransport

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :event_sales, EventSales.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :event_sales, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :event_sales, EventSalesWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  webhook_path_token =
    System.get_env("WEBHOOK_PATH_TOKEN") ||
      raise "environment variable WEBHOOK_PATH_TOKEN is missing."

  woocommerce_webhook_secret =
    System.get_env("WOOCOMMERCE_WEBHOOK_SECRET") ||
      raise "environment variable WOOCOMMERCE_WEBHOOK_SECRET is missing."

  config :event_sales, :webhook_intake,
    path_token: webhook_path_token,
    secret: woocommerce_webhook_secret

  buffer_enabled? = System.get_env("WEBHOOK_REDIS_BUFFER_ENABLED") in ~w(true 1)
  durability_accepted? = System.get_env("WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED") in ~w(true 1)

  if buffer_enabled? and durability_accepted? do
    redis_url =
      System.get_env("REDIS_URL") ||
        raise """
        REDIS_URL is required when WEBHOOK_REDIS_BUFFER_ENABLED=true and \
        WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED=true. \
        Degraded-mode buffering cannot run without Redis.
        """

    config :event_sales, :redis_webhook_buffer,
      enabled: true,
      durability_accepted: true,
      redis_url: redis_url,
      max_entries:
        String.to_integer(System.get_env("WEBHOOK_REDIS_BUFFER_MAX_ENTRIES") || "5000"),
      max_entry_bytes:
        String.to_integer(System.get_env("WEBHOOK_REDIS_BUFFER_MAX_ENTRY_BYTES") || "256000"),
      adapter: EventSales.Ingestion.RedisWebhookBuffer.RedixAdapter,
      key_prefix: "eventsales:webhook_buffer:v1"
  else
    config :event_sales, :redis_webhook_buffer,
      enabled: false,
      durability_accepted: false
  end

  hot_state_redis_enabled? = System.get_env("HOT_STATE_REDIS_SNAPSHOTS_ENABLED") in ~w(true 1)

  if hot_state_redis_enabled? do
    analytics_redis_url =
      System.get_env("HOT_STATE_REDIS_URL") ||
        System.get_env("REDIS_URL") ||
        raise "HOT_STATE_REDIS_URL or REDIS_URL is required when hot-state Redis snapshots are enabled."

    config :event_sales, :hot_state_aggregator,
      snapshot_adapter: EventSales.Analytics.SnapshotStore.RedixAdapter,
      snapshot_ttl_ms:
        String.to_integer(System.get_env("HOT_STATE_REDIS_SNAPSHOT_TTL_MS") || "3600000"),
      max_applied_event_ids:
        String.to_integer(System.get_env("HOT_STATE_MAX_APPLIED_EVENT_IDS") || "10000"),
      redis_enabled: true,
      redis_url: analytics_redis_url
  else
    config :event_sales, :hot_state_aggregator,
      snapshot_adapter: EventSales.Analytics.SnapshotStore.NoopAdapter,
      redis_enabled: false,
      redis_url: nil
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :event_sales, EventSalesWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :event_sales, EventSalesWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
