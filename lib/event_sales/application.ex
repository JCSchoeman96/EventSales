defmodule EventSales.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        EventSalesWeb.Telemetry,
        repo_child(),
        {DNSCluster, query: Application.get_env(:event_sales, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: EventSales.PubSub},
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
end
