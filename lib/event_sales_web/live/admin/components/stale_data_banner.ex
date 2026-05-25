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
      role="alert"
      class="alert alert-warning mb-6 shadow-sm"
    >
      <span>Dashboard data is {@hot_state[:state]}.</span>
    </div>
    """
  end
end
