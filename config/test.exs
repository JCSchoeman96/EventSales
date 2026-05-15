import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :event_sales, EventSales.Repo,
  username: System.get_env("TEST_DATABASE_USERNAME", "postgres"),
  password: System.get_env("TEST_DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("TEST_DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("TEST_DATABASE_PORT", "5432")),
  database:
    System.get_env(
      "TEST_DATABASE_NAME",
      "event_sales_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :event_sales, EventSalesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UK6gckLT7AiM/VwG9t4M3p4GHD8+EHC9f8pY1h/MwQWXTWm471spFxMc2+evtDDN",
  server: false

config :event_sales, :start_repo, true

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
