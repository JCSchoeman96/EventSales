defmodule EventSalesWeb.Live.Admin.Components.StaleDataBanner do
  @moduledoc """
  Presentational banner for dashboard hot-state freshness.
  """

  use Phoenix.Component

  attr :hot_state, :map, required: true

  def banner(assigns) do
    ~H"""
    <div
      :if={@hot_state[:state] in [:warming, :stale]}
      class="mb-6 border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
    >
      Dashboard data is {@hot_state[:state]}.
    </div>
    """
  end
end
