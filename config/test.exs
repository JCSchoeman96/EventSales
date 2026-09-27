import Config

test_host = System.get_env("TEST_DATABASE_HOST", "127.0.0.1")

test_port =
  String.to_integer(System.get_env("TEST_DATABASE_PORT", "55433"))

test_username = System.get_env("TEST_DATABASE_USERNAME", "eventsales_test")
test_database_base = System.get_env("TEST_DATABASE_NAME", "event_sales_test")
test_pool_size = String.to_integer(System.get_env("TEST_DATABASE_POOL_SIZE", "10"))
test_partition = System.get_env("MIX_TEST_PARTITION")

unless test_host == "127.0.0.1" and test_port == 55_433 do
  raise "EventSales tests must use the TEST PostgreSQL endpoint (127.0.0.1:55433)."
end

unless test_username == "eventsales_test" do
  raise "EventSales tests must use the non-superuser eventsales_test role."
end

unless Regex.match?(~r/\Aevent_sales_test(?:_[a-z0-9_]+)*\z/, test_database_base) do
  raise "TEST_DATABASE_NAME must start with event_sales_test and contain only lowercase letters, digits, and underscores."
end

if test_partition && not Regex.match?(~r/\A[0-9]+\z/, test_partition) do
  raise "MIX_TEST_PARTITION must be numeric so each test partition has a distinct database."
end

test_database = "#{test_database_base}#{test_partition}"

if byte_size(test_database) > 63 do
  raise "EventSales TEST database names cannot exceed 63 bytes."
end

config :event_sales, EventSales.Repo,
  username: test_username,
  password: System.get_env("TEST_DATABASE_PASSWORD", ""),
  hostname: test_host,
  port: test_port,
  database: test_database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_pool_size

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :event_sales, EventSalesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UK6gckLT7AiM/VwG9t4M3p4GHD8+EHC9f8pY1h/MwQWXTWm471spFxMc2+evtDDN",
  server: false

config :event_sales, :start_repo, true
config :event_sales, :start_database_readiness, false

config :event_sales, Oban, testing: :manual

config :event_sales, :webhook_intake,
  path_token: "test-token",
  secret: "slice_1_5_webhook_secret"

config :event_sales, :webhook_event_store, EventSales.TestSupport.Ingestion.StubWebhookEventStore

config :event_sales, :redis_webhook_buffer,
  enabled: true,
  durability_accepted: true,
  max_entries: 3,
  max_entry_bytes: 256_000,
  adapter: EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter

config :event_sales, :webhook_intake_rate_limit,
  enabled: true,
  window_ms: 60_000,
  max_requests: 10_000,
  key_prefix: "eventsales:test:webhook_rate_limit:v1",
  adapter: EventSales.TestSupport.Ingestion.MemoryRateLimiterAdapter,
  redis_url: nil

config :event_sales, :hot_state_aggregator,
  snapshot_adapter: EventSales.TestSupport.Analytics.MemorySnapshotStoreAdapter,
  snapshot_ttl_ms: 3_600_000,
  max_applied_event_ids: 1_000,
  rebuild_batch_size: 50,
  restore_scan_count: 100,
  restore_max_snapshots: 1_000,
  schedule_rebuild_on_boot?: false,
  stale_after_ms: 300_000,
  rebuild_in_flight_timeout_ms: 600_000,
  redis_enabled: false,
  redis_url: nil

config :event_sales, :woocommerce_rest,
  base_url: "https://woo.example.test",
  consumer_key: "ck_test",
  consumer_secret: "cs_test",
  timeout_ms: 1_000,
  queue_timeout_ms: 1_000,
  per_page: 100,
  max_pages: 50,
  max_concurrency: 2,
  transport: EventSales.Ingestion.Clients.HttpcTransport

config :event_sales, :woo_order_index,
  base_url: "https://wordpress.example.test",
  key_id: "order-index-key-1",
  secret: "order-index-secret",
  timeout_ms: 7_000,
  transport: EventSales.Ingestion.Clients.HttpcTransport

config :event_sales, :tickera_catalog_feed,
  base_url: "https://wordpress.example.test",
  secret: "test-feed-secret",
  timeout_ms: 1_000,
  per_page: 2,
  max_pages: 3,
  path: "/wp-json/eventsales/v1/tickera-catalog",
  transport: EventSales.Ingestion.Clients.HttpcTransport

config :event_sales, :rest_circuit_breaker,
  failure_threshold: 3,
  cooldown_ms: 30_000

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
