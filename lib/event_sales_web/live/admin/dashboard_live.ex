defmodule EventSalesWeb.Live.Admin.DashboardLive do
  @moduledoc """
  First useful internal admin dashboard.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Analytics.AdminDashboard
  alias EventSales.Analytics.HotStateAggregator
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  alias EventSalesWeb.Live.Components.{
    OrderTable,
    StaleDataBanner,
    StatCard,
    StatusBadge,
    UnmappedItemAlert
  }

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin Dashboard")
     |> assign(:current_user_id, current_user_id(session))
     |> load_dashboard()}
  end

  @impl true
  def handle_event("manual_refresh", _params, socket) do
    user_id = socket.assigns.current_user_id

    case ManualActionRateLimiter.allow?(user_id, :dashboard_refresh) do
      :ok ->
        result = HotStateAggregator.request_rebuild(:manual_refresh)

        {:noreply,
         socket
         |> put_refresh_flash(result)
         |> load_dashboard()}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Try again shortly")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-7xl px-6 py-8">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 class="text-2xl font-semibold text-zinc-900">Admin Dashboard</h1>
          <p class="text-sm text-zinc-600">Internal sales visibility from EventSales data.</p>
        </div>
        <button
          type="button"
          phx-click="manual_refresh"
          class="inline-flex items-center justify-center rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-zinc-50"
        >
          Refresh
        </button>
      </div>

      <StaleDataBanner.banner hot_state={@dashboard.hot_state} />

      <section class="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard.card title="Tickets Sold" value={@dashboard.kpis.total_sold} />
        <StatCard.card title="Revenue" value={format_money(@dashboard.kpis.total_revenue)} />
        <StatCard.card title="Today Tickets" value={@dashboard.kpis.today_sold} />
        <StatCard.card title="Today Revenue" value={format_money(@dashboard.kpis.today_revenue)} />
      </section>

      <section class="mb-6 grid gap-6 lg:grid-cols-2">
        <div>
          <h2 class="mb-3 text-base font-semibold text-zinc-900">Statuses</h2>
          <div class="flex flex-wrap gap-2">
            <StatusBadge.badge
              :for={{status, count} <- @dashboard.statuses}
              status={status}
              count={count}
            />
            <p :if={@dashboard.statuses == %{}} class="text-sm text-zinc-500">No statuses yet.</p>
          </div>
        </div>

        <div>
          <h2 class="mb-3 text-base font-semibold text-zinc-900">Unmapped Alerts</h2>
          <UnmappedItemAlert.list alerts={@dashboard.unmapped_alerts} />
        </div>
      </section>

      <section class="mb-6">
        <h2 class="mb-3 text-base font-semibold text-zinc-900">By Event</h2>
        <div class="overflow-x-auto border border-zinc-200">
          <table class="min-w-full divide-y divide-zinc-200 text-sm">
            <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
              <tr>
                <th class="px-3 py-2">Event</th>
                <th class="px-3 py-2">Tickets</th>
                <th class="px-3 py-2">Revenue</th>
                <th class="px-3 py-2">Today</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100 bg-white">
              <tr :for={event <- @dashboard.events}>
                <td class="px-3 py-2 font-medium text-zinc-900">{event.event_name}</td>
                <td class="px-3 py-2 text-zinc-700">{event.total_sold}</td>
                <td class="px-3 py-2 text-zinc-700">{format_money(event.total_revenue)}</td>
                <td class="px-3 py-2 text-zinc-700">{event.today_sold}</td>
              </tr>
              <tr :if={@dashboard.events == []}>
                <td class="px-3 py-6 text-center text-zinc-500" colspan="4">No events yet.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="mb-6">
        <h2 class="mb-3 text-base font-semibold text-zinc-900">By Ticket Type</h2>
        <div class="overflow-x-auto border border-zinc-200">
          <table class="min-w-full divide-y divide-zinc-200 text-sm">
            <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
              <tr>
                <th class="px-3 py-2">Event</th>
                <th class="px-3 py-2">Type</th>
                <th class="px-3 py-2">Tickets</th>
                <th class="px-3 py-2">Revenue</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100 bg-white">
              <tr :for={type <- @dashboard.ticket_types}>
                <td class="px-3 py-2 text-zinc-700">{type.event_name}</td>
                <td class="px-3 py-2 font-medium text-zinc-900">{type.ticket_type_name}</td>
                <td class="px-3 py-2 text-zinc-700">{type.total_sold}</td>
                <td class="px-3 py-2 text-zinc-700">{format_money(type.total_revenue)}</td>
              </tr>
              <tr :if={@dashboard.ticket_types == []}>
                <td class="px-3 py-6 text-center text-zinc-500" colspan="4">
                  No completed mapped ticket rows yet.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section>
        <h2 class="mb-3 text-base font-semibold text-zinc-900">Recent Orders</h2>
        <OrderTable.table orders={@dashboard.recent_orders} />
      </section>
    </main>
    """
  end

  defp load_dashboard(socket) do
    case AdminDashboard.snapshot() do
      {:ok, dashboard} ->
        assign(socket, dashboard: dashboard, load_error: nil)

      {:error, reason} ->
        socket
        |> assign(:load_error, reason)
        |> assign(:dashboard, empty_dashboard())
        |> put_flash(:error, "Dashboard data could not be loaded")
    end
  end

  defp put_refresh_flash(socket, :ok), do: put_flash(socket, :info, "Refresh requested")

  defp put_refresh_flash(socket, :already_running),
    do: put_flash(socket, :info, "Refresh requested")

  defp put_refresh_flash(socket, {:error, _reason}),
    do: put_flash(socket, :error, "Refresh failed")

  defp current_user_id(%{"current_user_id" => user_id}) when is_binary(user_id), do: user_id
  defp current_user_id(%{current_user_id: user_id}) when is_binary(user_id), do: user_id
  defp current_user_id(_session), do: "unknown"

  defp empty_dashboard do
    %{
      kpis: %{
        total_sold: 0,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0")
      },
      events: [],
      statuses: %{},
      ticket_types: [],
      recent_orders: [],
      unmapped_alerts: [],
      hot_state: %{state: :stale}
    }
  end

  defp format_money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_money(value), do: to_string(value)
end
