defmodule EventSalesWeb.Live.Admin.DashboardLive do
  @moduledoc """
  First useful internal admin dashboard.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Analytics.AdminDashboard
  alias EventSales.Analytics.DashboardPubSub
  alias EventSales.Analytics.HotStateAggregator
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  alias EventSalesWeb.Live.Admin.Components.{
    OrderTable,
    SalesChart,
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
     |> assign(:current_user_id, AdminSession.current_user_id(session))
     |> assign(:subscribed_event_ids, MapSet.new())
     |> load_dashboard()
     |> assign_chart_data()
     |> maybe_subscribe_to_event_topics()}
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
         |> load_dashboard()
         |> assign_chart_data()
         |> maybe_subscribe_to_event_topics()}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Try again shortly")}
    end
  end

  @impl true
  def handle_info({:hot_state_updated, event_id, _updated_at}, socket) when is_binary(event_id) do
    socket =
      case AdminDashboard.event_row(event_id) do
        {:ok, row} -> replace_event_row(socket, row)
        :not_found -> socket
        {:error, _reason} -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/dashboard"
      page_title="Admin Dashboard"
      page_description="Internal sales visibility from EventSales aggregates."
    >
      <:actions>
        <button type="button" phx-click="manual_refresh" class="btn btn-outline btn-sm shrink-0">
          Refresh
        </button>
      </:actions>

      <StaleDataBanner.banner hot_state={@dashboard.hot_state} />

      <section aria-labelledby="kpi-heading">
        <h2 id="kpi-heading" class="sr-only">Key metrics</h2>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <StatCard.card title="Tickets Sold" value={@dashboard.kpis.total_sold} />
          <StatCard.card title="Revenue" value={format_money(@dashboard.kpis.total_revenue)} />
          <StatCard.card title="Today Tickets" value={@dashboard.kpis.today_sold} />
          <StatCard.card title="Today Revenue" value={format_money(@dashboard.kpis.today_revenue)} />
        </div>
      </section>

      <section class="card bg-base-100 border border-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Sales Trend</h2>
          <.live_component
            module={SalesChart}
            id="main"
            labels={@chart_labels}
            revenue={@chart_revenue}
            tickets={@chart_tickets}
          />
        </div>
      </section>

      <section class="grid gap-6 lg:grid-cols-2">
        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Statuses</h2>
            <div class="flex flex-wrap gap-2">
              <StatusBadge.badge
                :for={{status, count} <- Enum.sort(@dashboard.statuses)}
                status={status}
                count={count}
              />
              <p :if={@dashboard.statuses == %{}} class="text-sm text-base-content/60">
                No statuses yet.
              </p>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">Unmapped Alerts</h2>
            <UnmappedItemAlert.list alerts={@dashboard.unmapped_alerts} />
          </div>
        </div>
      </section>

      <section class="card bg-base-100 border border-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">By Event</h2>
          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Event</th>
                  <th>Tickets</th>
                  <th>Revenue</th>
                  <th>Today</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @dashboard.events}>
                  <td class="font-medium">{event.event_name}</td>
                  <td>{event.total_sold}</td>
                  <td>{format_money(event.total_revenue)}</td>
                  <td>{event.today_sold}</td>
                </tr>
                <tr :if={@dashboard.events == []}>
                  <td class="text-center text-base-content/60" colspan="4">No events yet.</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section class="card bg-base-100 border border-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">By Ticket Type</h2>
          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Event</th>
                  <th>Type</th>
                  <th>Tickets</th>
                  <th>Revenue</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={type <- @dashboard.ticket_types}>
                  <td>{type.event_name}</td>
                  <td class="font-medium">{type.ticket_type_name}</td>
                  <td>{type.total_sold}</td>
                  <td>{format_money(type.total_revenue)}</td>
                </tr>
                <tr :if={@dashboard.ticket_types == []}>
                  <td class="text-center text-base-content/60" colspan="4">
                    No completed mapped ticket rows yet.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section>
        <h2 class="mb-3 text-base font-semibold text-base-content">Recent Orders</h2>
        <OrderTable.table orders={@dashboard.recent_orders} />
      </section>
    </AdminShell.shell>
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

  defp assign_chart_data(socket) do
    # Chart data — replace with real query result when AdminDashboard.daily_buckets/2 exists
    daily = Map.get(socket.assigns.dashboard, :daily_buckets, [])

    socket
    |> assign(
      :chart_labels,
      Enum.map(daily, fn %{date: %Date{} = date} -> Date.to_string(date) end)
    )
    |> assign(
      :chart_revenue,
      Enum.map(daily, fn %{revenue_cents: cents} when is_integer(cents) -> div(cents, 100) end)
    )
    |> assign(
      :chart_tickets,
      Enum.map(daily, fn %{tickets_sold: sold} when is_integer(sold) -> sold end)
    )
  rescue
    _ ->
      socket
      |> assign(:chart_labels, [])
      |> assign(:chart_revenue, [])
      |> assign(:chart_tickets, [])
  end

  defp maybe_subscribe_to_event_topics(socket) do
    if connected?(socket) do
      subscribed_event_ids = socket.assigns.subscribed_event_ids

      socket.assigns.dashboard.events
      |> Enum.map(& &1.event_id)
      |> Enum.reject(&MapSet.member?(subscribed_event_ids, &1))
      |> Enum.each(&DashboardPubSub.subscribe_event/1)
      |> then(fn _ ->
        assign(socket, :subscribed_event_ids, all_displayed_event_ids(socket))
      end)
    else
      socket
    end
  end

  defp all_displayed_event_ids(socket) do
    socket.assigns.dashboard.events
    |> Enum.map(& &1.event_id)
    |> MapSet.new()
    |> MapSet.union(socket.assigns.subscribed_event_ids)
  end

  defp replace_event_row(socket, row) do
    case AdminDashboard.replace_event_row(socket.assigns.dashboard, row) do
      {:ok, dashboard} -> assign(socket, :dashboard, dashboard)
      :not_found -> socket
    end
  end

  defp put_refresh_flash(socket, :ok), do: put_flash(socket, :info, "Refresh requested")

  defp put_refresh_flash(socket, :already_running),
    do: put_flash(socket, :info, "Refresh requested")

  defp put_refresh_flash(socket, {:error, _reason}),
    do: put_flash(socket, :error, "Refresh failed")

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
