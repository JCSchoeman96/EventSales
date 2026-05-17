defmodule EventSalesWeb.Live.Admin.MappingsLive do
  @moduledoc """
  Read-only internal queue for order items needing mapping attention.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Sales.OrderItemMapper

  @queue_limit 50

  @impl true
  def mount(_params, _session, socket) do
    case OrderItemMapper.list_unmapped_queue(limit: @queue_limit) do
      {:ok, items} ->
        {:ok, assign(socket, queue_items: items)}

      {:error, reason} ->
        {:ok, assign(socket, queue_items: [], load_error: inspect(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl px-6 py-8">
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-zinc-900">Mapping Queue</h1>
      </div>

      <%= if assigns[:load_error] do %>
        <p class="mb-4 rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-900">
          Could not load mapping queue.
        </p>
      <% end %>

      <div class="overflow-x-auto border border-zinc-200">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Order</th>
              <th class="px-3 py-2">Item</th>
              <th class="px-3 py-2">Product</th>
              <th class="px-3 py-2">Variation</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Qty</th>
              <th class="px-3 py-2">Updated</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 bg-white">
            <tr :for={item <- @queue_items}>
              <td class="px-3 py-2 text-zinc-700">{order_number(item)}</td>
              <td class="px-3 py-2 font-medium text-zinc-900">{item.name}</td>
              <td class="px-3 py-2 text-zinc-700">{item.woo_product_id}</td>
              <td class="px-3 py-2 text-zinc-700">{item.woo_variation_id || "-"}</td>
              <td class="px-3 py-2 text-zinc-700">{item.mapping_status}</td>
              <td class="px-3 py-2 text-zinc-700">{item.quantity}</td>
              <td class="px-3 py-2 text-zinc-700">{format_datetime(item.updated_at)}</td>
            </tr>
            <tr :if={@queue_items == []}>
              <td class="px-3 py-6 text-center text-zinc-500" colspan="7">
                No mapping rows need attention.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </main>
    """
  end

  defp order_number(%{order: %{order_number: order_number}}) when is_binary(order_number),
    do: order_number

  defp order_number(_item), do: "-"

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
