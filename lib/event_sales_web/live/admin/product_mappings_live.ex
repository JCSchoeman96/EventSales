defmodule EventSalesWeb.Live.Admin.ProductMappingsLive do
  @moduledoc """
  Read-only admin view of catalog product mappings.
  """

  use EventSalesWeb, :live_view

  require Ash.Query

  alias EventSales.Analytics.EventDetail
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @impl true
  def mount(_params, session, socket) do
    filters = %{"event_id" => "", "woo_product_id" => ""}

    socket =
      socket
      |> assign(:page_title, "Product Mappings")
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:filters, filters)
      |> assign(:events, [])
      |> assign(:mappings, [])
      |> load_events()
      |> load_mappings()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:filters, normalize_filters(filters))
     |> load_mappings()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/mappings"
      page_title="Product Mappings"
      page_description="Read-only catalog mapping visibility for WooCommerce products and ticket types."
    >
      <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="mb-4 text-base font-semibold text-base-content">Filters</h2>
          <form id="mapping-filters" phx-change="filter" class="grid gap-4 md:grid-cols-2">
            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Event</span>
              </span>
              <select
                name="filters[event_id]"
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              >
                <option value="" selected={@filters["event_id"] == ""}>All events</option>
                <option
                  :for={event <- @events}
                  value={event.event_id}
                  selected={@filters["event_id"] == event.event_id}
                >
                  {event.event_name}
                </option>
              </select>
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Woo product ID</span>
              </span>
              <input
                type="text"
                name="filters[woo_product_id]"
                value={@filters["woo_product_id"]}
                placeholder="e.g. 109740"
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
            </label>
          </form>
        </div>
      </section>

      <section class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Event</th>
              <th>Ticket type</th>
              <th>Woo product</th>
              <th>Woo variation</th>
              <th>Current label</th>
              <th>Active</th>
              <th>Source system</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={mapping <- @mappings}>
              <td class="font-medium text-base-content">{event_name(mapping)}</td>
              <td class="text-base-content/80">{ticket_type_name(mapping)}</td>
              <td class="text-base-content/80">{mapping.woo_product_id}</td>
              <td class="text-base-content/80">{mapping.woo_variation_id || "-"}</td>
              <td class="text-base-content/80">
                {mapping.current_label || mapping.original_label || "-"}
              </td>
              <td class="text-base-content/80">{mapping.active}</td>
              <td class="text-base-content/80">{source_system_name(mapping)}</td>
            </tr>
            <tr :if={@mappings == []}>
              <td class="px-3 py-6 text-center text-base-content/60" colspan="7">
                No product mappings match the current filters.
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </AdminShell.shell>
    """
  end

  defp load_events(socket) do
    case EventDetail.list_events(actor: socket.assigns.current_user, page: 1, per_page: 100) do
      {:ok, %{rows: events}} -> assign(socket, :events, events)
      {:error, _reason} -> assign(socket, :events, [])
    end
  end

  defp load_mappings(socket) do
    query =
      ProductMapping
      |> Ash.Query.load([:event, :ticket_type, :source_system])
      |> Ash.Query.sort(woo_product_id: :asc, woo_variation_id: :asc)
      |> maybe_filter_event(socket.assigns.filters["event_id"])
      |> maybe_filter_product(socket.assigns.filters["woo_product_id"])

    case Ash.read(query, domain: Catalog) do
      {:ok, mappings} -> assign(socket, :mappings, mappings)
      {:error, _reason} -> assign(socket, :mappings, [])
    end
  end

  defp maybe_filter_event(query, ""), do: query

  defp maybe_filter_event(query, event_id) when is_binary(event_id) do
    Ash.Query.filter(query, event_id == ^event_id)
  end

  defp maybe_filter_product(query, ""), do: query

  defp maybe_filter_product(query, product_id) when is_binary(product_id) do
    case Integer.parse(String.trim(product_id)) do
      {id, ""} -> Ash.Query.filter(query, woo_product_id == ^id)
      _other -> query
    end
  end

  defp normalize_filters(filters) do
    %{
      "event_id" => Map.get(filters, "event_id", ""),
      "woo_product_id" => Map.get(filters, "woo_product_id", "")
    }
  end

  defp event_name(%{event: %{name: name}}), do: name
  defp event_name(_mapping), do: "-"

  defp ticket_type_name(%{ticket_type: %{name: name}}), do: name
  defp ticket_type_name(_mapping), do: "-"

  defp source_system_name(%{source_system: %{name: name}}), do: name
  defp source_system_name(_mapping), do: "-"
end
