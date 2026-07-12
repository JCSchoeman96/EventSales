defmodule EventSalesWeb.Live.Admin.UnmappedAlertResolveLive do
  @moduledoc """
  Admin review workflow for mapping and recovering a single unmapped alert.
  """

  use EventSalesWeb, :live_view

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.ManualMappingCreator
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Sales.UnmappedAlertResolver
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @empty_form %{
    "event_id" => "",
    "ticket_type_mode" => "existing",
    "ticket_type_id" => "",
    "ticket_type_name" => "",
    "source_status" => "manual",
    "reason" => ""
  }

  @impl true
  def mount(%{"order_item_id" => order_item_id}, session, socket) do
    current_user = AdminSession.current_user(session)

    socket =
      socket
      |> assign(:page_title, "Resolve Unmapped Alert")
      |> assign(:current_user, current_user)
      |> assign(:order_item_id, order_item_id)
      |> assign(:alert, nil)
      |> assign(:source_system, nil)
      |> assign(:events, [])
      |> assign(:ticket_types, [])
      |> assign(:form, @empty_form)
      |> assign(:error, nil)
      |> assign(:result, nil)
      |> load_alert()

    {:ok, socket}
  end

  @impl true
  def handle_event("update_form", %{"manual_mapping" => params}, socket) do
    form = normalize_form(params)
    {:noreply, socket |> assign(:form, form) |> assign(:error, nil) |> load_ticket_types()}
  end

  def handle_event("resolve", %{"manual_mapping" => params}, socket) do
    form = normalize_form(params)

    case UnmappedAlertResolver.resolve(socket.assigns.order_item_id, form,
           actor: socket.assigns.current_user
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:result, result.recovery)
         |> assign(:error, nil)
         |> put_flash(:info, "Unmapped alert resolved")}

      {:error, {:recovery_failed, _reason}} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:error, error_message(:recovery_failed))
         |> assign(:result, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:error, error_message(reason))
         |> assign(:result, nil)}
    end
  end

  def handle_event("retry_recovery", _params, socket) do
    case UnmappedAlertResolver.retry_recovery(socket.assigns.order_item_id,
           actor: socket.assigns.current_user
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:result, result)
         |> assign(:error, nil)
         |> put_flash(:info, "Mapping recovery completed")}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, error_message(:recovery_failed))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/unmapped-alerts"
      page_title="Resolve Unmapped Alert"
      page_description="Create a reviewed local mapping and retry matching pending order items."
    >
      <div class="flex flex-wrap gap-2">
        <.link href={~p"/admin/dashboard"} class="btn btn-ghost btn-sm">Back to dashboard</.link>
        <.link href={~p"/admin/mappings"} class="btn btn-outline btn-sm">Product mappings</.link>
      </div>

      <div :if={@error} class="alert alert-error text-sm" role="alert">
        <span>{@error}</span>
        <button
          :if={@error == error_message(:recovery_failed)}
          type="button"
          phx-click="retry_recovery"
          class="btn btn-sm"
        >
          Retry recovery
        </button>
      </div>

      <section :if={@alert} class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Alert context</h2>
          <dl class="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <.context label="Order" value={@alert.order_number || "-"} />
            <.context label="Item" value={@alert.name} />
            <.context label="Woo product" value={@alert.woo_product_id} />
            <.context label="Woo variation" value={@alert.woo_variation_id || "-"} />
            <.context label="Mapping status" value={@alert.mapping_status} />
            <.context label="Quantity" value={@alert.quantity} />
            <.context label="Source system" value={source_name(@source_system)} />
            <.context label="Updated" value={format_datetime(@alert.updated_at)} />
          </dl>
        </div>
      </section>

      <section :if={@result} class="card border border-success/40 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Recovery result</h2>
          <div class="stats stats-vertical border border-base-300 sm:stats-horizontal">
            <.stat label="Mapped" value={@result.mapped} />
            <.stat label="Marked unmapped" value={@result.marked_unmapped} />
            <.stat label="Unchanged" value={@result.unchanged} />
          </div>
        </div>
      </section>

      <section :if={@alert && !@result} class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-base">Mapping decision</h2>
          <form
            id="unmapped-alert-resolution-form"
            phx-change="update_form"
            phx-submit="resolve"
            class="grid gap-4 lg:grid-cols-2"
          >
            <.select_field
              label="Event"
              name="manual_mapping[event_id]"
              value={@form["event_id"]}
              options={Enum.map(@events, &{&1.name, &1.id})}
              prompt="Select event"
            />
            <.select_field
              label="Ticket type mode"
              name="manual_mapping[ticket_type_mode]"
              value={@form["ticket_type_mode"]}
              options={[{"Existing ticket type", "existing"}, {"New ticket type", "new"}]}
            />
            <.select_field
              label="Existing ticket type"
              name="manual_mapping[ticket_type_id]"
              value={@form["ticket_type_id"]}
              options={Enum.map(@ticket_types, &{&1.name, &1.id})}
              prompt="Select ticket type"
              disabled={@form["ticket_type_mode"] == "new"}
            />
            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium">New ticket type name</span>
              </span>
              <input
                name="manual_mapping[ticket_type_name]"
                value={@form["ticket_type_name"]}
                disabled={@form["ticket_type_mode"] == "existing"}
                class="input input-bordered w-full disabled:opacity-60"
              />
            </label>
            <.select_field
              label="Source status"
              name="manual_mapping[source_status]"
              value={@form["source_status"]}
              options={Enum.map(ManualMappingCreator.source_statuses(), &{&1, &1})}
            />
            <label class="form-control w-full lg:col-span-2">
              <span class="label"><span class="label-text font-medium">Reason</span></span>
              <textarea
                name="manual_mapping[reason]"
                rows="3"
                class="textarea textarea-bordered w-full"
              >{@form["reason"]}</textarea>
            </label>
            <div class="lg:col-span-2">
              <button type="submit" class="btn btn-primary" phx-disable-with="Resolving...">
                Resolve alert
              </button>
            </div>
          </form>
        </div>
      </section>
    </AdminShell.shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp context(assigns) do
    ~H"""
    <div>
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="font-medium text-base-content">{@value}</dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="stat py-3">
      <div class="stat-title text-xs">{@label}</div>
      <div class="stat-value text-2xl">{@value}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :disabled, :boolean, default: false

  defp select_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label"><span class="label-text font-medium">{@label}</span></span>
      <select
        name={@name}
        disabled={@disabled}
        class="select select-bordered w-full disabled:opacity-60"
      >
        <option :if={@prompt} value="" selected={@value == ""}>{@prompt}</option>
        <option :for={{label, value} <- @options} value={value} selected={@value == value}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  defp load_alert(socket) do
    case UnmappedAlertResolver.load(socket.assigns.order_item_id,
           actor: socket.assigns.current_user
         ) do
      {:ok, alert} ->
        socket
        |> assign(:alert, alert)
        |> load_source_system()
        |> load_events()
        |> load_ticket_types()

      {:error, reason} ->
        assign(socket, :error, error_message(reason))
    end
  end

  defp load_source_system(socket) do
    source =
      case Ash.get(SourceSystem, socket.assigns.alert.source_system_id,
             domain: Catalog,
             actor: socket.assigns.current_user
           ) do
        {:ok, source} -> source
        _other -> nil
      end

    assign(socket, :source_system, source)
  end

  defp load_events(socket) do
    source_id = socket.assigns.alert.source_system_id

    events =
      Event
      |> Ash.Query.filter(source_system_id == ^source_id)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(200)
      |> Ash.read(domain: Catalog, actor: socket.assigns.current_user)
      |> case do
        {:ok, rows} -> rows
        _other -> []
      end

    assign(socket, :events, events)
  end

  defp load_ticket_types(socket) do
    event_id = socket.assigns.form["event_id"]

    ticket_types =
      if event_id == "" do
        []
      else
        TicketType
        |> Ash.Query.filter(event_id == ^event_id)
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.limit(200)
        |> Ash.read(domain: Catalog, actor: socket.assigns.current_user)
        |> case do
          {:ok, rows} -> rows
          _other -> []
        end
      end

    assign(socket, :ticket_types, ticket_types)
  end

  defp normalize_form(params), do: Map.merge(@empty_form, Map.take(params, Map.keys(@empty_form)))

  defp source_name(%SourceSystem{name: name}), do: name
  defp source_name(_source), do: "Unavailable"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(_datetime), do: "-"

  defp error_message(:not_found), do: "This unmapped alert could not be found."
  defp error_message(:not_pending), do: "This alert is no longer pending mapping resolution."

  defp error_message(:duplicate_mapping),
    do: "An active mapping already exists for this Woo product and variation."

  defp error_message(:event_source_mismatch),
    do: "The selected event does not belong to this source system."

  defp error_message(:ticket_type_event_mismatch),
    do: "The selected ticket type does not belong to the event."

  defp error_message(:recovery_failed),
    do: "The mapping was saved, but matching rows could not be recovered."

  defp error_message(:event_required), do: "Select an event."
  defp error_message(:ticket_type_required), do: "Select a ticket type."
  defp error_message(:ticket_type_name_required), do: "Enter a ticket type name."
  defp error_message(:reason_required), do: "Enter a reason."
  defp error_message(_reason), do: "The unmapped alert could not be resolved."
end
