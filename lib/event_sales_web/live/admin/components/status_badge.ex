defmodule EventSalesWeb.Live.Admin.Components.StatusBadge do
  @moduledoc """
  Presentational status badge for dashboard status counts.
  """

  use Phoenix.Component

  attr :status, :any, required: true
  attr :count, :integer, required: true

  def badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 rounded border border-zinc-200 bg-white px-2.5 py-1 text-sm text-zinc-700">
      <span class="font-medium">{@status}</span>
      <span class="text-zinc-500">{@count}</span>
    </span>
    """
  end
end
