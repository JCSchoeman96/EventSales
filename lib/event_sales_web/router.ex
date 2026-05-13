defmodule EventSalesWeb.Router do
  use EventSalesWeb, :router
  import AshAdmin.Router

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
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EventSalesWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :internal_tools do
    plug EventSalesWeb.Plugs.InternalOnly
  end

  scope "/", EventSalesWeb do
    get "/health", HealthController, :show
  end

  scope "/", EventSalesWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/" do
    pipe_through [:browser, :internal_tools]

    ash_admin("/internal/ash-admin")
  end

  # Other scopes may use custom stacks.
  # scope "/api", EventSalesWeb do
  #   pipe_through :api
  # end
end
