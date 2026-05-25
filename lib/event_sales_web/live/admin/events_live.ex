defmodule EventSalesWeb.Live.Admin.EventsLive do
  @moduledoc """
  Admin event list for Slice 12.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Analytics.EventDetail
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Pagination, as: AdminPagination
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Events")
     |> assign(:current_user, AdminSession.current_user(session))
     |> load_events(1)}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    page = socket.assigns.page.page + 1
    {:noreply, load_events(socket, page)}
  end

  def handle_event("previous_page", _params, socket) do
    page = max(socket.assigns.page.page - 1, 1)
    {:noreply, load_events(socket, page)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/events"
      page_title="Events"
      page_description="Admin event sales summaries from EventSales data."
    >
      <:actions>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            disabled
            class="btn btn-outline btn-sm"
          >
            Export CSV
          </button>
          <.link
            navigate={~p"/admin/imports"}
            class="btn btn-primary btn-sm"
          >
            Import CSV
          </.link>
        </div>
      </:actions>

      <section>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th class="px-3 py-2">Event</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Capacity</th>
                <th class="px-3 py-2">Sold</th>
                <th class="px-3 py-2">Remaining</th>
                <th class="px-3 py-2">Revenue</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={event <- @events}>
                <td class="px-3 py-2 font-medium text-base-content">
                  <.link navigate={~p"/admin/events/#{event.event_id}"} class="hover:underline">
                    {event.event_name}
                  </.link>
                  <div class="text-xs font-normal text-base-content/60">{event.slug}</div>
                </td>
                <td class="px-3 py-2">{event.status}</td>
                <td class="px-3 py-2">{format_count(event.capacity)}</td>
                <td class="px-3 py-2">{event.sold}</td>
                <td class="px-3 py-2">{format_count(event.remaining)}</td>
                <td class="px-3 py-2">{format_money(event.revenue)}</td>
              </tr>
              <tr :if={@events == []}>
                <td class="px-3 py-6 text-center text-base-content/60" colspan="6">No events yet.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="mt-4 flex items-center justify-between">
          <button
            type="button"
            phx-click="previous_page"
            disabled={!@page.has_previous?}
            class="btn btn-outline btn-sm"
          >
            Previous
          </button>
          <span class="text-sm text-base-content/70">Page {@page.page}</span>
          <button
            type="button"
            phx-click="next_page"
            disabled={!@page.has_next?}
            class="btn btn-outline btn-sm"
          >
            Next
          </button>
        </div>
      </section>
    </AdminShell.shell>
    """
  end

  defp load_events(socket, page) do
    case EventDetail.list_events(actor: socket.assigns.current_user, page: page) do
      {:ok, %{rows: rows, page: page_info}} ->
        socket
        |> assign(:events, rows)
        |> assign(:page, page_info)

      {:error, :forbidden} ->
        socket
        |> assign(:events, [])
        |> assign(:page, AdminPagination.empty_page())
        |> put_flash(:error, "Events could not be loaded")

      {:error, _reason} ->
        socket
        |> assign(:events, [])
        |> assign(:page, AdminPagination.empty_page())
        |> put_flash(:error, "Events could not be loaded")
    end
  end

  defp format_count(nil), do: "Uncapped"
  defp format_count(value), do: to_string(value)

  defp format_money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_money(value), do: to_string(value)
end
