defmodule EventSalesWeb.Router do
  use EventSalesWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EventSalesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EventSalesWeb do
    get "/health", HealthController, :show
  end

  scope "/", EventSalesWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", EventSalesWeb do
  #   pipe_through :api
  # end
end
