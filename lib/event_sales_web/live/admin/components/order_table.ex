defmodule EventSalesWeb.Live.Admin.Components.OrderTable do
  @moduledoc """
  Presentational recent-order table for the admin dashboard.
  """

  use Phoenix.Component

  attr :orders, :list, required: true

  def table(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body p-0">
        <div class="overflow-x-auto">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th>Order</th>
                <th>Status</th>
                <th>Total</th>
                <th>Completed</th>
                <th>Source Updated</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={order <- @orders}>
                <td class="font-medium">{order.order_number}</td>
                <td>
                  <span class={order_status_classes(to_string(order.status))}>
                    {order.status}
                  </span>
                </td>
                <td>
                  {order.currency} {format_money(order.raw_total)}
                </td>
                <td>{format_datetime(order.completed_at)}</td>
                <td>{format_datetime(order.updated_at_source)}</td>
              </tr>
              <tr :if={@orders == []}>
                <td class="text-center text-base-content/60" colspan="5">No recent orders.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp order_status_classes("completed"), do: "badge badge-success badge-sm"
  defp order_status_classes("processing"), do: "badge badge-success badge-sm"
  defp order_status_classes("pending"), do: "badge badge-warning badge-sm"
  defp order_status_classes("on-hold"), do: "badge badge-warning badge-sm"
  defp order_status_classes("refunded"), do: "badge badge-error badge-sm"
  defp order_status_classes("cancelled"), do: "badge badge-error badge-sm"
  defp order_status_classes("failed"), do: "badge badge-error badge-sm"
  defp order_status_classes(_), do: "badge badge-info badge-sm"

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_money(value), do: to_string(value)
end
