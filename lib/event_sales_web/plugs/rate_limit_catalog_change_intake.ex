defmodule EventSalesWeb.Plugs.RateLimitCatalogChangeIntake do
  @moduledoc "Dedicated catalogue-change router rate-limit boundary."
  def init(opts), do: opts
  def call(conn, opts), do: EventSalesWeb.Plugs.RateLimitWebhookIntake.call(conn, opts)
end
