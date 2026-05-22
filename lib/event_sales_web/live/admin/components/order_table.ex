defmodule EventSalesWeb.Live.Admin.Components.OrderTable do
  @moduledoc """
  Presentational recent-order table for the admin dashboard.
  """

  use Phoenix.Component

  attr :orders, :list, required: true

  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto border border-zinc-200">
      <table class="min-w-full divide-y divide-zinc-200 text-sm">
        <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
          <tr>
            <th class="px-3 py-2">Order</th>
            <th class="px-3 py-2">Status</th>
            <th class="px-3 py-2">Total</th>
            <th class="px-3 py-2">Completed</th>
            <th class="px-3 py-2">Source Updated</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 bg-white">
          <tr :for={order <- @orders}>
            <td class="px-3 py-2 font-medium text-zinc-900">{order.order_number}</td>
            <td class="px-3 py-2 text-zinc-700">{order.status}</td>
            <td class="px-3 py-2 text-zinc-700">
              {order.currency} {format_money(order.raw_total)}
            </td>
            <td class="px-3 py-2 text-zinc-700">{format_datetime(order.completed_at)}</td>
            <td class="px-3 py-2 text-zinc-700">{format_datetime(order.updated_at_source)}</td>
          </tr>
          <tr :if={@orders == []}>
            <td class="px-3 py-6 text-center text-zinc-500" colspan="5">No recent orders.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_money(value), do: to_string(value)
end
