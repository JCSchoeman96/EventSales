defmodule EventSalesWeb.Live.Admin.Components.StatCard do
  @moduledoc """
  Presentational statistic card for admin dashboard metrics.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :value, :any, required: true

  def card(assigns) do
    ~H"""
    <div class="stat rounded-box border border-base-200 bg-base-100 px-4 py-3 shadow-sm">
      <div class="stat-title text-xs uppercase opacity-70">{@title}</div>
      <div class="stat-value text-2xl">{@value}</div>
    </div>
    """
  end
end
