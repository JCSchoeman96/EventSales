defmodule EventSales.Repo do
  use Ecto.Repo,
    otp_app: :event_sales,
    adapter: Ecto.Adapters.Postgres
end
