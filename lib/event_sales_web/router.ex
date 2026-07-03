defmodule EventSalesWeb.Router do
  use EventSalesWeb, :router
  import AshAdmin.Router
  import Oban.Web.Router

  @content_security_policy (case Mix.env() do
                              :dev ->
                                "default-src 'self'; base-uri 'self'; frame-ancestors 'self'; " <>
                                  "form-action 'self'; img-src 'self' data:; object-src 'none'; " <>
                                  "script-src 'self' 'unsafe-inline' 'unsafe-eval'; " <>
                                  "style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:"

                              _ ->
                                "default-src 'self'; base-uri 'self'; frame-ancestors 'self'; " <>
                                  "form-action 'self'; img-src 'self' data:; object-src 'none'; " <>
                                  "script-src 'self'; style-src 'self'; connect-src 'self'"
                            end)

  pipeline :browser do
    plug :accepts, ["html"]
    plug EventSalesWeb.Plugs.RateLimitManualActions
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EventSalesWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook_intake do
    plug EventSalesWeb.Plugs.RateLimitWebhookIntake
  end

  pipeline :internal_admin_tools do
    plug EventSalesWeb.Plugs.InternalOnly
    plug EventSalesWeb.Plugs.LoadCurrentUser
    plug EventSalesWeb.Plugs.AdminOnly
  end

  pipeline :admin_dashboard do
    plug EventSalesWeb.Plugs.LoadCurrentUser
    plug EventSalesWeb.Plugs.AdminOnly
  end

  scope "/", EventSalesWeb do
    get "/health", HealthController, :show
  end

  scope "/webhooks", EventSalesWeb do
    pipe_through :webhook_intake

    post "/woocommerce/:path_token", WebhookController, :woocommerce
  end

  scope "/", EventSalesWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/admin", EventSalesWeb do
    pipe_through :browser

    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create
    delete "/logout", AdminSessionController, :delete
  end

  scope "/" do
    pipe_through [:browser, :internal_admin_tools]

    live "/internal/mappings", EventSalesWeb.Live.Admin.MappingsLive

    ash_admin("/internal/ash-admin")
  end

  scope "/admin", EventSalesWeb do
    pipe_through [:browser, :admin_dashboard]

    live "/dashboard", Live.Admin.DashboardLive
    live "/events", Live.Admin.EventsLive
    live "/events/:id", Live.Admin.EventDetailLive
    get "/events/:event_id/exports/summary.csv", Admin.EventExportController, :summary
    get "/events/:event_id/exports/orders.csv", Admin.EventExportController, :orders
    live "/imports", Live.Admin.ImportsLive
    live "/webhooks", Live.Admin.WebhooksLive
    live "/sync", Live.Admin.SyncLive
    live "/reconciliation", Live.Admin.ReconciliationLive
    get "/reconciliation/export.csv", Admin.ReconciliationExportController, :show

    oban_dashboard("/oban",
      resolver: EventSalesWeb.ObanWebResolver,
      oban_name: Oban,
      as: :oban_dashboard
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", EventSalesWeb do
  #   pipe_through :api
  # end
end
