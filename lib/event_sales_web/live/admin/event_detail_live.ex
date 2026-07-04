defmodule EventSalesWeb.Live.Admin.EventDetailLive do
  @moduledoc """
  Admin event detail page for Slice 12.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Accounts.PiiPolicy
  alias EventSales.Analytics.{DashboardPubSub, EventDetail}
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Pagination, as: AdminPagination
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession
  alias EventSalesWeb.Presenters.CustomerPresenter

  @impl true
  def mount(%{"id" => event_id}, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Event Detail")
      |> assign(:event_id, event_id)
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:not_found?, false)
      |> stream_configure(:recent_orders, dom_id: &"recent-order-#{&1.order_id}")
      |> stream_configure(:unmapped_items, dom_id: &"unmapped-item-#{&1.order_item_id}")
      |> load_detail()
      |> load_recent_orders(1)
      |> load_unmapped_items(1)
      |> maybe_subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_event("next_recent_orders_page", _params, socket) do
    page = socket.assigns.recent_orders_page.page + 1
    {:noreply, load_recent_orders(socket, page)}
  end

  def handle_event("previous_recent_orders_page", _params, socket) do
    page = max(socket.assigns.recent_orders_page.page - 1, 1)
    {:noreply, load_recent_orders(socket, page)}
  end

  def handle_event("next_unmapped_items_page", _params, socket) do
    page = socket.assigns.unmapped_items_page.page + 1
    {:noreply, load_unmapped_items(socket, page)}
  end

  def handle_event("previous_unmapped_items_page", _params, socket) do
    page = max(socket.assigns.unmapped_items_page.page - 1, 1)
    {:noreply, load_unmapped_items(socket, page)}
  end

  @impl true
  def handle_info({:hot_state_updated, event_id, _updated_at}, socket)
      when is_binary(event_id) do
    if event_id == socket.assigns.event_id do
      {:noreply, load_detail(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(%{not_found?: true} = assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/events"
      page_title="Event not found"
      page_description="The requested event is not available."
    >
      <.link
        navigate={~p"/admin/events"}
        class="text-sm font-medium text-base-content/80 hover:underline"
      >
        Back to events
      </.link>
      <div class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h1 class="text-2xl font-semibold text-base-content">Event not found</h1>
          <p class="mt-2 text-sm text-base-content/70">The requested event is not available.</p>
        </div>
      </div>
    </AdminShell.shell>
    """
  end

  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/events"
      page_title={@detail.event_name}
      page_description={"#{@detail.slug} - #{@detail.status}"}
    >
      <:actions>
        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/admin/events"} class="btn btn-ghost btn-sm">
            Back to events
          </.link>
          <.link
            href={~p"/admin/events/#{@event_id}/exports/summary.csv"}
            class="btn btn-outline btn-sm"
          >
            Summary CSV
          </.link>
          <.link
            href={~p"/admin/events/#{@event_id}/exports/orders.csv"}
            class="btn btn-outline btn-sm"
          >
            Orders CSV
          </.link>
          <.link
            navigate={~p"/admin/imports?event_id=#{@event_id}"}
            class="btn btn-primary btn-sm"
          >
            Import CSV
          </.link>
        </div>
      </:actions>

      <section class="mb-6 grid gap-3 sm:grid-cols-3">
        <div class="border border-base-300 bg-base-100 p-4">
          <div class="text-xs font-semibold uppercase text-base-content/60">Capacity</div>
          <div class="mt-1 text-2xl font-semibold text-base-content">
            {format_count(@detail.capacity)}
          </div>
        </div>
        <div class="border border-base-300 bg-base-100 p-4">
          <div class="text-xs font-semibold uppercase text-base-content/60">Sold</div>
          <div class="mt-1 text-2xl font-semibold text-base-content">{@detail.sold}</div>
        </div>
        <div class="border border-base-300 bg-base-100 p-4">
          <div class="text-xs font-semibold uppercase text-base-content/60">Remaining</div>
          <div class="mt-1 text-2xl font-semibold text-base-content">
            {format_count(@detail.remaining)}
          </div>
        </div>
      </section>

      <section class="mb-6 grid gap-6 lg:grid-cols-2">
        <div>
          <h2 class="mb-3 text-base font-semibold text-base-content">Statuses</h2>
          <div class="flex flex-wrap gap-2">
            <span
              :for={{status, count} <- @detail.status_breakdown}
              class="inline-flex items-center gap-2 rounded border border-base-300 bg-base-200 px-2 py-1 text-sm text-base-content"
            >
              <span>{status}</span>
              <span class="font-semibold">{count}</span>
            </span>
            <p :if={@detail.status_breakdown == %{}} class="text-sm text-base-content/60">
              No statuses yet.
            </p>
          </div>
        </div>
        <div>
          <h2 class="mb-3 text-base font-semibold text-base-content">Revenue</h2>
          <div class="text-2xl font-semibold text-base-content">{format_money(@detail.revenue)}</div>
        </div>
      </section>

      <section class="mb-6">
        <h2 class="mb-3 text-base font-semibold text-base-content">Ticket Types</h2>
        <div class="overflow-x-auto border border-base-300">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th class="px-3 py-2">Type</th>
                <th class="px-3 py-2">Capacity</th>
                <th class="px-3 py-2">Sold</th>
                <th class="px-3 py-2">Remaining</th>
                <th class="px-3 py-2">Revenue</th>
              </tr>
            </thead>
            <tbody class="">
              <tr :for={type <- @detail.ticket_types}>
                <td class="px-3 py-2 font-medium text-base-content">{type.ticket_type_name}</td>
                <td class="px-3 py-2 text-base-content/80">{format_count(type.capacity)}</td>
                <td class="px-3 py-2 text-base-content/80">{type.sold}</td>
                <td class="px-3 py-2 text-base-content/80">{format_count(type.remaining)}</td>
                <td class="px-3 py-2 text-base-content/80">{format_money(type.revenue)}</td>
              </tr>
              <tr :if={@detail.ticket_types == []}>
                <td class="px-3 py-6 text-center text-base-content/60" colspan="5">
                  No ticket types yet.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="mb-6">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-base font-semibold text-base-content">Recent Orders</h2>
          <span class="text-sm text-base-content/70">Page {@recent_orders_page.page}</span>
        </div>
        <div class="overflow-x-auto border border-base-300">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th class="px-3 py-2">Order</th>
                <th class="px-3 py-2">Customer</th>
                <th class="px-3 py-2">Email</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Total</th>
                <th class="px-3 py-2">Completed</th>
                <th class="px-3 py-2">Source Updated</th>
              </tr>
            </thead>
            <tbody id="recent-orders" phx-update="stream" class="">
              <tr :for={{dom_id, order} <- @streams.recent_orders} id={dom_id}>
                <td class="px-3 py-2 font-medium text-base-content">{order.order_number}</td>
                <td class="px-3 py-2 text-base-content/80">{order.customer_name || "-"}</td>
                <td class="px-3 py-2 text-base-content/80">{order.customer_email || "-"}</td>
                <td class="px-3 py-2 text-base-content/80">{order.status}</td>
                <td class="px-3 py-2 text-base-content/80">{format_money(order.raw_total)}</td>
                <td class="px-3 py-2 text-base-content/80">{format_datetime(order.completed_at)}</td>
                <td class="px-3 py-2 text-base-content/80">
                  {format_datetime(order.updated_at_source)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="mt-3 flex items-center justify-between">
          <button
            type="button"
            phx-click="previous_recent_orders_page"
            disabled={!@recent_orders_page.has_previous?}
            class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium text-base-content disabled:cursor-not-allowed disabled:bg-base-200 disabled:text-base-content/50"
          >
            Previous
          </button>
          <button
            type="button"
            phx-click="next_recent_orders_page"
            disabled={!@recent_orders_page.has_next?}
            class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium text-base-content disabled:cursor-not-allowed disabled:bg-base-200 disabled:text-base-content/50"
          >
            Next
          </button>
        </div>
      </section>

      <section>
        <div class="mb-3 flex items-center justify-between">
          <h2 class="text-base font-semibold text-base-content">Unmapped Items</h2>
          <span class="text-sm text-base-content/70">Page {@unmapped_items_page.page}</span>
        </div>
        <div class="overflow-x-auto border border-base-300">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th class="px-3 py-2">Item</th>
                <th class="px-3 py-2">Order</th>
                <th class="px-3 py-2">Product</th>
                <th class="px-3 py-2">Quantity</th>
                <th class="px-3 py-2">Status</th>
              </tr>
            </thead>
            <tbody id="unmapped-items" phx-update="stream" class="">
              <tr :for={{dom_id, item} <- @streams.unmapped_items} id={dom_id}>
                <td class="px-3 py-2 font-medium text-base-content">{item.name}</td>
                <td class="px-3 py-2 text-base-content/80">{item.order_number}</td>
                <td class="px-3 py-2 text-base-content/80">
                  {item.woo_product_id}/{item.woo_variation_id || "-"}
                </td>
                <td class="px-3 py-2 text-base-content/80">{item.quantity}</td>
                <td class="px-3 py-2 text-base-content/80">{item.mapping_status}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="mt-3 flex items-center justify-between">
          <button
            type="button"
            phx-click="previous_unmapped_items_page"
            disabled={!@unmapped_items_page.has_previous?}
            class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium text-base-content disabled:cursor-not-allowed disabled:bg-base-200 disabled:text-base-content/50"
          >
            Previous
          </button>
          <button
            type="button"
            phx-click="next_unmapped_items_page"
            disabled={!@unmapped_items_page.has_next?}
            class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium text-base-content disabled:cursor-not-allowed disabled:bg-base-200 disabled:text-base-content/50"
          >
            Next
          </button>
        </div>
      </section>
    </AdminShell.shell>
    """
  end

  defp load_detail(socket) do
    case EventDetail.get_event_detail(socket.assigns.event_id, actor: socket.assigns.current_user) do
      {:ok, detail} ->
        socket
        |> assign(:detail, detail)
        |> assign(:not_found?, false)

      :not_found ->
        socket
        |> assign(:detail, empty_detail(socket.assigns.event_id))
        |> assign(:not_found?, true)

      {:error, _reason} ->
        socket
        |> assign(:detail, empty_detail(socket.assigns.event_id))
        |> assign(:not_found?, false)
        |> put_flash(:error, "Event detail could not be loaded")
    end
  end

  defp load_recent_orders(%{assigns: %{not_found?: true}} = socket, _page) do
    socket
    |> assign(:recent_orders_page, AdminPagination.empty_page())
    |> stream(:recent_orders, [], reset: true)
  end

  defp load_recent_orders(socket, page) do
    case EventDetail.recent_orders(socket.assigns.event_id,
           actor: socket.assigns.current_user,
           page: page
         ) do
      {:ok, %{rows: rows, page: page_info}} ->
        rows = present_recent_order_customers(rows, socket.assigns.current_user)

        socket
        |> assign(:recent_orders_page, page_info)
        |> stream(:recent_orders, rows, reset: true)

      {:error, _reason} ->
        socket
        |> assign(:recent_orders_page, AdminPagination.empty_page())
        |> stream(:recent_orders, [], reset: true)
    end
  end

  defp load_unmapped_items(%{assigns: %{not_found?: true}} = socket, _page) do
    socket
    |> assign(:unmapped_items_page, AdminPagination.empty_page())
    |> stream(:unmapped_items, [], reset: true)
  end

  defp load_unmapped_items(socket, page) do
    case EventDetail.unmapped_items(socket.assigns.event_id,
           actor: socket.assigns.current_user,
           page: page
         ) do
      {:ok, %{rows: rows, page: page_info}} ->
        socket
        |> assign(:unmapped_items_page, page_info)
        |> stream(:unmapped_items, rows, reset: true)

      {:error, _reason} ->
        socket
        |> assign(:unmapped_items_page, AdminPagination.empty_page())
        |> stream(:unmapped_items, [], reset: true)
    end
  end

  defp maybe_subscribe(%{assigns: %{not_found?: true}} = socket), do: socket

  defp maybe_subscribe(socket) do
    if connected?(socket) do
      DashboardPubSub.subscribe_event(socket.assigns.event_id)
    end

    socket
  end

  defp present_recent_order_customers(rows, current_user) do
    visibility = PiiPolicy.customer_pii_visibility(current_user, context: :customer_record)

    Enum.map(rows, fn row ->
      Map.merge(row, CustomerPresenter.present(row, pii_visibility: visibility))
    end)
  end

  defp empty_detail(event_id) do
    %{
      event_id: event_id,
      event_name: "",
      slug: "",
      status: :unknown,
      capacity: nil,
      sold: 0,
      remaining: nil,
      revenue: Decimal.new("0"),
      currency: Application.fetch_env!(:event_sales, :default_currency),
      refreshed_at: nil,
      status_breakdown: %{},
      ticket_types: []
    }
  end

  defp format_count(nil), do: "Uncapped"
  defp format_count(value), do: to_string(value)

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_money(value), do: to_string(value)
end
