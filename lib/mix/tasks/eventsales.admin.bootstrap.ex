defmodule Mix.Tasks.Eventsales.Admin.Bootstrap do
  @moduledoc """
  Bootstraps the first EventSales admin from environment variables.
  """

  use Mix.Task

  alias EventSales.Maintenance.AdminBootstrap

  @shortdoc "Bootstraps an EventSales admin account"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    result = AdminBootstrap.run!()

    Mix.shell().info("admin user: #{result.user_status}")
    if result.password_rotated?, do: Mix.shell().info("password: rotated")
    Mix.shell().info("role: ensured")
  rescue
    error in ArgumentError -> Mix.raise(error.message)
  end
end
