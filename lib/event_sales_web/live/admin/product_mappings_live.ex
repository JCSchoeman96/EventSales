defmodule EventSalesWeb.Live.Admin.ProductMappingsLive do
  @moduledoc """
  Admin view for catalog product mappings and controlled manual mapping creation.
  """

  use EventSalesWeb, :live_view

  require Ash.Query

  alias EventSales.Analytics.EventDetail
  alias EventSales.Catalog
  alias EventSales.Catalog.ManualMappingCreator
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Catalog.{VariationMappingResolver, VariationMappingReview}
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @mapping_list_limit 200
  @empty_manual_form %{
    "source_system_id" => "",
    "event_id" => "",
    "ticket_type_mode" => "existing",
    "ticket_type_id" => "",
    "ticket_type_name" => "",
    "woo_product_id" => "",
    "woo_variation_id" => "",
    "label" => "",
    "source_status" => "manual",
    "reason" => ""
  }

  @impl true
  def mount(params, session, socket) do
    filters = %{"event_id" => "", "woo_product_id" => ""}

    socket =
      socket
      |> assign(:page_title, "Product Mappings")
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:filters, filters)
      |> assign(:manual_form, @empty_manual_form)
      |> assign(:manual_form_error, nil)
      |> assign(:resolution, nil)
      |> assign(:resolution_error, nil)
      |> assign(:source_systems, [])
      |> assign(:events, [])
      |> assign(:catalog_events, [])
      |> assign(:ticket_types, [])
      |> assign(:mappings, [])
      |> load_source_systems()
      |> load_events()
      |> load_catalog_events()
      |> load_resolution(params)
      |> load_ticket_types()
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

  def handle_event("update_manual_form", %{"manual_mapping" => form}, socket) do
    form = form |> normalize_manual_form() |> lock_resolution_identity(socket.assigns.resolution)

    {:noreply,
     socket
     |> assign(:manual_form, form)
     |> assign(:manual_form_error, nil)
     |> load_ticket_types()}
  end

  def handle_event("create_manual_mapping", %{"manual_mapping" => form}, socket) do
    form = form |> normalize_manual_form() |> lock_resolution_identity(socket.assigns.resolution)

    case create_mapping(socket, form) do
      {:ok, _result} ->
        message =
          if socket.assigns.resolution,
            do:
              "Mapping created and audited. Run catalogue-dry-run --fresh before reviewing or applying catalogue changes.",
            else: "Manual mapping created"

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(:manual_form, reset_manual_form(form))
         |> assign(:manual_form_error, nil)
         |> load_ticket_types()
         |> load_mappings()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:manual_form, form)
         |> assign(:manual_form_error, error_message(reason))
         |> load_ticket_types()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/mappings"
      page_title="Product Mappings"
      page_description="Catalog mapping visibility and controlled manual mapping creation."
    >
      <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="mb-4 text-base font-semibold text-base-content">Create manual mapping</h2>
          <div
            :if={@resolution}
            class="alert alert-warning mb-4 items-start py-3 text-sm"
          >
            <div>
              <div class="font-semibold">
                The selected dry-run was revoked before manual catalogue changes.
              </div>
              <div>After resolving mappings, run a fresh catalogue dry-run.</div>
            </div>
          </div>
          <div :if={@resolution_error} class="alert alert-error mb-4 py-3 text-sm">
            {@resolution_error}
          </div>
          <div :if={@manual_form_error} class="alert alert-error mb-4 py-3 text-sm">
            {@manual_form_error}
          </div>
          <form
            id="manual-mapping-form"
            phx-change="update_manual_form"
            phx-submit="create_manual_mapping"
            class="grid gap-4 lg:grid-cols-2"
          >
            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Source system</span>
              </span>
              <select
                name="manual_mapping[source_system_id]"
                disabled={!is_nil(@resolution)}
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              >
                <option value="" selected={@manual_form["source_system_id"] == ""}>
                  Select source
                </option>
                <option
                  :for={source <- @source_systems}
                  value={source.id}
                  selected={@manual_form["source_system_id"] == source.id}
                >
                  {source.name}
                </option>
              </select>
              <input
                :if={@resolution}
                type="hidden"
                name="manual_mapping[source_system_id]"
                value={@manual_form["source_system_id"]}
              />
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Event</span>
              </span>
              <select
                name="manual_mapping[event_id]"
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              >
                <option value="" selected={@manual_form["event_id"] == ""}>Select event</option>
                <option
                  :for={event <- manual_events(@catalog_events, @manual_form)}
                  value={event.id}
                  selected={@manual_form["event_id"] == event.id}
                >
                  {event.name}
                </option>
              </select>
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Ticket type mode</span>
              </span>
              <select
                name="manual_mapping[ticket_type_mode]"
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              >
                <option value="existing" selected={@manual_form["ticket_type_mode"] == "existing"}>
                  Existing ticket type
                </option>
                <option value="new" selected={@manual_form["ticket_type_mode"] == "new"}>
                  New ticket type
                </option>
              </select>
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Existing ticket type</span>
              </span>
              <select
                name="manual_mapping[ticket_type_id]"
                disabled={@manual_form["ticket_type_mode"] == "new"}
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60 disabled:opacity-60"
              >
                <option value="" selected={@manual_form["ticket_type_id"] == ""}>
                  Select ticket type
                </option>
                <option
                  :for={ticket <- @ticket_types}
                  value={ticket.id}
                  selected={@manual_form["ticket_type_id"] == ticket.id}
                >
                  {ticket.name}
                </option>
              </select>
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">New ticket type name</span>
              </span>
              <input
                type="text"
                name="manual_mapping[ticket_type_name]"
                value={@manual_form["ticket_type_name"]}
                disabled={@manual_form["ticket_type_mode"] == "existing"}
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60 disabled:opacity-60"
              />
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Woo product ID</span>
              </span>
              <input
                type="text"
                name="manual_mapping[woo_product_id]"
                value={@manual_form["woo_product_id"]}
                readonly={!is_nil(@resolution)}
                placeholder="e.g. 104324"
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Woo variation ID</span>
              </span>
              <input
                type="text"
                name="manual_mapping[woo_variation_id]"
                value={@manual_form["woo_variation_id"]}
                readonly={!is_nil(@resolution)}
                placeholder="Optional"
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Label</span>
              </span>
              <input
                type="text"
                name="manual_mapping[label]"
                value={@manual_form["label"]}
                readonly={!is_nil(@resolution)}
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
            </label>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Source status</span>
              </span>
              <select
                name="manual_mapping[source_status]"
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              >
                <option
                  :for={status <- ManualMappingCreator.source_statuses()}
                  value={status}
                  selected={@manual_form["source_status"] == status}
                >
                  {status}
                </option>
              </select>
            </label>

            <label class="form-control w-full lg:col-span-2">
              <span class="label">
                <span class="label-text font-medium text-base-content">Reason</span>
              </span>
              <textarea
                name="manual_mapping[reason]"
                rows="3"
                class="textarea textarea-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              >{@manual_form["reason"]}</textarea>
            </label>

            <div class="lg:col-span-2">
              <button type="submit" class="btn btn-primary" phx-disable-with="Creating...">
                Create manual mapping
              </button>
            </div>
          </form>
        </div>
      </section>

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

  defp load_source_systems(socket) do
    query =
      SourceSystem
      |> Ash.Query.filter(kind == :woocommerce and active == true)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(100)

    case Ash.read(query, domain: Catalog, actor: socket.assigns.current_user) do
      {:ok, source_systems} -> assign(socket, :source_systems, source_systems)
      {:error, _reason} -> assign(socket, :source_systems, [])
    end
  end

  defp load_events(socket) do
    case EventDetail.list_events(actor: socket.assigns.current_user, page: 1, per_page: 100) do
      {:ok, %{rows: events}} -> assign(socket, :events, events)
      {:error, _reason} -> assign(socket, :events, [])
    end
  end

  defp load_catalog_events(socket) do
    query =
      Event
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(200)

    case Ash.read(query, domain: Catalog, actor: socket.assigns.current_user) do
      {:ok, events} -> assign(socket, :catalog_events, events)
      {:error, _reason} -> assign(socket, :catalog_events, [])
    end
  end

  defp load_ticket_types(socket) do
    event_id = socket.assigns.manual_form["event_id"]

    query =
      TicketType
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(200)
      |> maybe_filter_ticket_event(event_id)

    case Ash.read(query, domain: Catalog, actor: socket.assigns.current_user) do
      {:ok, ticket_types} -> assign(socket, :ticket_types, ticket_types)
      {:error, _reason} -> assign(socket, :ticket_types, [])
    end
  end

  defp load_resolution(socket, params) when is_map(params) do
    keys = ~w(run_id dry_run_hash woo_product_id woo_variation_id)

    if Enum.any?(keys, &present?(Map.get(params, &1))) do
      with true <- Enum.all?(keys, &present?(Map.get(params, &1))),
           {:ok, review} <-
             VariationMappingReview.list(params["run_id"], params["dry_run_hash"],
               actor: socket.assigns.current_user
             ),
           {:ok, product_id} <- cast_positive_integer(params["woo_product_id"]),
           {:ok, variation_id} <- cast_positive_integer(params["woo_variation_id"]),
           %{} = row <-
             Enum.find(
               review.rows,
               &(&1.woo_product_id == product_id and &1.woo_variation_id == variation_id)
             ),
           true <- row.manual_action_allowed do
        resolution = %{
          run_id: review.run_id,
          dry_run_hash: review.dry_run_hash,
          woo_product_id: product_id,
          woo_variation_id: variation_id
        }

        form =
          @empty_manual_form
          |> Map.merge(%{
            "source_system_id" => review.source_system_id,
            "woo_product_id" => Integer.to_string(product_id),
            "woo_variation_id" => Integer.to_string(variation_id),
            "label" => row.source_label || ""
          })

        socket
        |> assign(:resolution, resolution)
        |> assign(:resolution_error, nil)
        |> assign(:manual_form, form)
      else
        _other ->
          socket
          |> assign(:resolution, nil)
          |> assign(:resolution_error, "The variation resolution link is stale or invalid.")
      end
    else
      socket
    end
  end

  defp create_mapping(%{assigns: %{resolution: nil}} = socket, form) do
    ManualMappingCreator.create(form, actor: socket.assigns.current_user)
  end

  defp create_mapping(%{assigns: %{resolution: resolution}} = socket, form) do
    VariationMappingResolver.resolve(
      resolution.run_id,
      resolution.dry_run_hash,
      resolution.woo_product_id,
      resolution.woo_variation_id,
      form,
      actor: socket.assigns.current_user
    )
  end

  defp load_mappings(socket) do
    query =
      ProductMapping
      |> Ash.Query.load([:event, :ticket_type, :source_system])
      |> Ash.Query.sort(woo_product_id: :asc, woo_variation_id: :asc)
      |> Ash.Query.limit(@mapping_list_limit)
      |> maybe_filter_event(socket.assigns.filters["event_id"])
      |> maybe_filter_product(socket.assigns.filters["woo_product_id"])

    case Ash.read(query, domain: Catalog, actor: socket.assigns.current_user) do
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

  defp maybe_filter_ticket_event(query, ""), do: Ash.Query.filter(query, false)

  defp maybe_filter_ticket_event(query, event_id) when is_binary(event_id) do
    Ash.Query.filter(query, event_id == ^event_id)
  end

  defp normalize_filters(filters) do
    %{
      "event_id" => Map.get(filters, "event_id", ""),
      "woo_product_id" => Map.get(filters, "woo_product_id", "")
    }
  end

  defp normalize_manual_form(form) do
    @empty_manual_form
    |> Map.merge(Map.take(form, Map.keys(@empty_manual_form)))
    |> normalize_manual_selection()
  end

  defp normalize_manual_selection(%{"ticket_type_mode" => mode} = form)
       when mode in ["existing", "new"] do
    form
  end

  defp normalize_manual_selection(form), do: Map.put(form, "ticket_type_mode", "existing")

  defp lock_resolution_identity(form, nil), do: form

  defp lock_resolution_identity(form, resolution) do
    form
    |> Map.put("woo_product_id", Integer.to_string(resolution.woo_product_id))
    |> Map.put("woo_variation_id", Integer.to_string(resolution.woo_variation_id))
  end

  defp reset_manual_form(form) do
    @empty_manual_form
    |> Map.put("source_system_id", form["source_system_id"])
    |> Map.put("event_id", form["event_id"])
    |> Map.put("ticket_type_mode", form["ticket_type_mode"])
    |> Map.put("ticket_type_id", form["ticket_type_id"])
    |> Map.put(
      "ticket_type_name",
      if(form["ticket_type_mode"] == "new", do: "", else: form["ticket_type_name"])
    )
    |> Map.put("source_status", form["source_status"])
  end

  defp manual_events(events, %{"source_system_id" => ""}), do: events

  defp manual_events(events, %{"source_system_id" => source_system_id}) do
    Enum.filter(events, &(&1.source_system_id == source_system_id))
  end

  defp error_message(:duplicate_mapping),
    do: "An active mapping already exists for that Woo product and variation."

  defp error_message(:forbidden), do: "You are not allowed to create manual mappings."
  defp error_message(:source_required), do: "Select a source system."
  defp error_message(:event_required), do: "Select an event."
  defp error_message(:ticket_type_required), do: "Select a ticket type."
  defp error_message(:ticket_type_name_required), do: "Enter a ticket type name."
  defp error_message(:invalid_woo_product_id), do: "Woo product ID must be a positive integer."

  defp error_message(:invalid_woo_variation_id),
    do: "Woo variation ID must be blank or a positive integer."

  defp error_message(:label_required), do: "Enter a label."
  defp error_message(:reason_required), do: "Enter a reason."
  defp error_message(:source_status_required), do: "Select a source status."
  defp error_message(:invalid_source_status), do: "Select a valid source status."
  defp error_message(:invalid_source_system), do: "Select an active WooCommerce source system."
  defp error_message(:source_not_found), do: "Select an active WooCommerce source system."
  defp error_message(:event_not_found), do: "Select a valid event."

  defp error_message(:event_source_mismatch),
    do: "Selected event does not belong to the source system."

  defp error_message(:ticket_type_not_found), do: "Select a valid ticket type."

  defp error_message(:ticket_type_event_mismatch),
    do: "Selected ticket type does not belong to the event."

  defp error_message(:ticket_type_create_failed), do: "Ticket type could not be created."
  defp error_message(:mapping_create_failed), do: "Manual mapping could not be created."
  defp error_message(:audit_failed), do: "Manual mapping audit could not be written."
  defp error_message(_reason), do: "Manual mapping could not be created."

  defp event_name(%{event: %{name: name}}), do: name
  defp event_name(_mapping), do: "-"

  defp ticket_type_name(%{ticket_type: %{name: name}}), do: name
  defp ticket_type_name(_mapping), do: "-"

  defp source_system_name(%{source_system: %{name: name}}), do: name
  defp source_system_name(_mapping), do: "-"

  defp cast_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, :invalid_integer}
    end
  end

  defp cast_positive_integer(_value), do: {:error, :invalid_integer}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
