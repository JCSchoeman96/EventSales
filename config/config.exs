# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :event_sales,
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
  plugins: false,
  queues: [default: 10, webhooks: 10]

config :event_sales, :redis_webhook_buffer,
  enabled: false,
  durability_accepted: false,
  max_entries: 5_000,
  max_entry_bytes: 256_000,
  adapter: EventSales.Ingestion.RedisWebhookBuffer.RedixAdapter,
  redis_url: nil,
  key_prefix: "eventsales:webhook_buffer:v1"

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
