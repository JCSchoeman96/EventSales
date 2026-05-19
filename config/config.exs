# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :event_sales,
  env: config_env(),
  ash_domains: [
    EventSales.AshBaseline.Domain,
    EventSales.Accounts,
    EventSales.Catalog,
    EventSales.Sales,
    EventSales.Ingestion,
    EventSales.Analytics,
    EventSales.Audit
  ],
  ecto_repos: [EventSales.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :event_sales, :internal_tools, ash_admin_enabled: config_env() in [:dev, :test]

config :event_sales, Oban,
  repo: EventSales.Repo,
  notifier: Oban.Notifiers.Postgres,
  plugins: [],
  queues: [
    default: 10,
    webhooks: 10,
    analytics_rebuilds: 1,
    reconciliation: 1,
    tickera_sync: 1,
    tickera_reconciliation: 1
  ]

config :event_sales, :tickera_reconciliation, stale_snapshot_after_hours: 24

config :event_sales, :redis_webhook_buffer,
  enabled: false,
  durability_accepted: false,
  max_entries: 5_000,
  max_entry_bytes: 256_000,
  adapter: EventSales.Ingestion.RedisWebhookBuffer.RedixAdapter,
  redis_url: nil,
  key_prefix: "eventsales:webhook_buffer:v1"

config :event_sales, :hot_state_aggregator,
  snapshot_adapter: EventSales.Analytics.SnapshotStore.NoopAdapter,
  snapshot_ttl_ms: :timer.hours(1),
  max_applied_event_ids: 10_000,
  rebuild_batch_size: 50,
  restore_scan_count: 100,
  restore_max_snapshots: 1_000,
  schedule_rebuild_on_boot?: true,
  stale_after_ms: 300_000,
  rebuild_in_flight_timeout_ms: 600_000,
  redis_enabled: false,
  redis_url: nil

config :event_sales, :woocommerce_rest,
  base_url: nil,
  consumer_key: nil,
  consumer_secret: nil,
  timeout_ms: 5_000,
  queue_timeout_ms: 5_000,
  per_page: 100,
  max_pages: 50,
  max_concurrency: 2,
  transport: EventSales.Ingestion.Clients.HttpcTransport

config :event_sales, :tickera_api,
  default_site_url: "https://voelgoed.co.za",
  timeout_ms: 30_000,
  connect_timeout_ms: 5_000,
  receive_timeout_ms: 30_000,
  per_page: 50,
  page_delay_ms: 100,
  transport: EventSales.Ingestion.Clients.HttpcTransport

config :event_sales, :rest_circuit_breaker,
  failure_threshold: 3,
  cooldown_ms: 30_000

config :event_sales, :reconciliation_peak_guard,
  weekdays: [1, 2, 3, 4, 5],
  max_days: 7

# Configure the endpoint
config :event_sales, EventSalesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EventSalesWeb.ErrorHTML, json: EventSalesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EventSales.PubSub,
  live_view: [signing_salt: "O10HBPsn"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
