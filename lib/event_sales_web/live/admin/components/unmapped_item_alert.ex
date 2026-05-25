defmodule EventSalesWeb.Live.Admin.Components.UnmappedItemAlert do
  @moduledoc """
  Presentational alert list for unmapped dashboard rows.
  """

  use Phoenix.Component

  attr :alerts, :list, required: true

  def list(assigns) do
    ~H"""
    <div class="space-y-2">
      <div
        :for={alert <- @alerts}
        role="alert"
        class="alert alert-warning alert-soft text-sm"
      >
        <div>
          <div class="font-medium">{alert.name}</div>
          <div class="text-sm opacity-90">
            {alert.order_number || "-"} — product {alert.woo_product_id} — {alert.mapping_status}
          </div>
        </div>
      </div>
      <p :if={@alerts == []} class="text-sm text-base-content/60">
        No unmapped rows need attention.
      </p>
    </div>
    """
  end
end
