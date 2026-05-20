defmodule EventSalesWeb.Live.Admin.EventsLive do
  @moduledoc """
  Admin event list for Slice 12.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Analytics.EventDetail
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
    <main class="mx-auto max-w-7xl px-6 py-8">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 class="text-2xl font-semibold text-zinc-900">Events</h1>
          <p class="text-sm text-zinc-600">Admin event sales summaries from EventSales data.</p>
        </div>
        <div class="flex gap-2">
          <button
            type="button"
            disabled
            class="inline-flex items-center justify-center rounded border border-zinc-200 bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-500"
          >
            Export CSV
          </button>
          <button
            type="button"
            disabled
            class="inline-flex items-center justify-center rounded border border-zinc-200 bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-500"
          >
            Import CSV
          </button>
        </div>
      </div>

      <section>
        <div class="overflow-x-auto border border-zinc-200">
          <table class="min-w-full divide-y divide-zinc-200 text-sm">
            <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
              <tr>
                <th class="px-3 py-2">Event</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Capacity</th>
                <th class="px-3 py-2">Sold</th>
                <th class="px-3 py-2">Remaining</th>
                <th class="px-3 py-2">Revenue</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100 bg-white">
              <tr :for={event <- @events}>
                <td class="px-3 py-2 font-medium text-zinc-900">
                  <.link navigate={~p"/admin/events/#{event.event_id}"} class="hover:underline">
                    {event.event_name}
                  </.link>
                  <div class="text-xs font-normal text-zinc-500">{event.slug}</div>
                </td>
                <td class="px-3 py-2 text-zinc-700">{event.status}</td>
                <td class="px-3 py-2 text-zinc-700">{format_count(event.capacity)}</td>
                <td class="px-3 py-2 text-zinc-700">{event.sold}</td>
                <td class="px-3 py-2 text-zinc-700">{format_count(event.remaining)}</td>
                <td class="px-3 py-2 text-zinc-700">{format_money(event.revenue)}</td>
              </tr>
              <tr :if={@events == []}>
                <td class="px-3 py-6 text-center text-zinc-500" colspan="6">No events yet.</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="mt-4 flex items-center justify-between">
          <button
            type="button"
            phx-click="previous_page"
            disabled={!@page.has_previous?}
            class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800 disabled:cursor-not-allowed disabled:bg-zinc-100 disabled:text-zinc-400"
          >
            Previous
          </button>
          <span class="text-sm text-zinc-600">Page {@page.page}</span>
          <button
            type="button"
            phx-click="next_page"
            disabled={!@page.has_next?}
            class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800 disabled:cursor-not-allowed disabled:bg-zinc-100 disabled:text-zinc-400"
          >
            Next
          </button>
        </div>
      </section>
    </main>
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
