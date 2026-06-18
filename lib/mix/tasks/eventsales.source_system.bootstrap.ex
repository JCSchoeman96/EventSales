defmodule Mix.Tasks.Eventsales.SourceSystem.Bootstrap do
  @moduledoc """
  Bootstraps the active WooCommerce source system from environment variables.
  """

  use Mix.Task

  alias EventSales.Maintenance.SourceSystemBootstrap

  @shortdoc "Bootstraps the active WooCommerce source system"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    result = SourceSystemBootstrap.run!()

    Mix.shell().info("source system: #{result.name}")
    Mix.shell().info("kind: woocommerce")
    Mix.shell().info("source: #{result.status}")
  rescue
    error in ArgumentError -> Mix.raise(error.message)
  end
end
