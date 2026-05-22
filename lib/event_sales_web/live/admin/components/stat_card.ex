defmodule EventSalesWeb.Live.Admin.Components.StatCard do
  @moduledoc """
  Presentational statistic card for admin dashboard metrics.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :value, :any, required: true

  def card(assigns) do
    ~H"""
    <div class="border border-zinc-200 bg-white p-4">
      <p class="text-xs font-semibold uppercase text-zinc-500">{@title}</p>
      <p class="mt-2 text-2xl font-semibold text-zinc-900">{@value}</p>
    </div>
    """
  end
end
