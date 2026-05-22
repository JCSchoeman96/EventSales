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
        class="border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
      >
        <div class="font-medium">{alert.name}</div>
        <div class="text-amber-900">
          {alert.order_number || "-"} - product {alert.woo_product_id} - {alert.mapping_status}
        </div>
      </div>
      <p :if={@alerts == []} class="text-sm text-zinc-500">No unmapped rows need attention.</p>
    </div>
    """
  end
end
