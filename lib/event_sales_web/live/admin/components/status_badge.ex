defmodule EventSalesWeb.Live.Admin.Components.StatusBadge do
  @moduledoc """
  Presentational status badge for dashboard status counts.
  """

  use Phoenix.Component

  attr :status, :any, required: true
  attr :count, :integer, required: true

  def badge(assigns) do
    ~H"""
    <span class={badge_classes(to_string(@status))}>
      <span class="font-medium">{@status}</span>
      <span class="opacity-70">{@count}</span>
    </span>
    """
  end

  defp badge_classes("completed"), do: "badge badge-success badge-lg gap-2"
  defp badge_classes("processing"), do: "badge badge-success badge-lg gap-2"
  defp badge_classes("pending"), do: "badge badge-warning badge-lg gap-2"
  defp badge_classes("on-hold"), do: "badge badge-warning badge-lg gap-2"
  defp badge_classes("refunded"), do: "badge badge-error badge-lg gap-2"
  defp badge_classes("cancelled"), do: "badge badge-error badge-lg gap-2"
  defp badge_classes("failed"), do: "badge badge-error badge-lg gap-2"
  defp badge_classes(_), do: "badge badge-info badge-lg gap-2"
end
