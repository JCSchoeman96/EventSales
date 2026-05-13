defmodule EventSales.Repo do
  use AshPostgres.Repo, otp_app: :event_sales

  def installed_extensions do
    ["ash-functions"]
  end

  def min_pg_version do
    Version.parse!("16.0.0")
  end
end
