defmodule EventSalesWeb.Live.Admin.ReconciliationLive do
  @moduledoc """
  Admin Tickera/Woo reconciliation review UI (index).
  """

  use EventSalesWeb, :live_view

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User
  alias EventSales.Analytics.EventDetail
  alias EventSales.Ingestion.AdminReconciliationDashboard
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  @empty_filters %{
    "event_id" => "",
    "tickera_event_source_id" => "",
    "tickera_reconciliation_run_id" => "",
    "status" => "",
    "severity" => "",
    "finding_type" => "",
    "ticket_type_id" => "",
    "woo_order_status" => "",
    "tickera_payment_status" => "",
    "last_seen_from" => "",
    "last_seen_to" => ""
  }

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Reconciliation")
      |> assign(:current_user, current_user(session))
      |> assign(:current_user_id, current_user_id(session))
      |> assign(:filters, @empty_filters)
      |> assign(:action_event_id, "")
      |> assign(:confirm_attendee_sync, false)
      |> assign(:confirm_reconciliation, false)
      |> assign(:expanded_finding_id, nil)
      |> assign(:expanded_finding, nil)
      |> assign(:resolution_note, "")
      |> assign(:events, [])
      |> assign(:snapshot, empty_snapshot())
      |> assign(:runs, [])
      |> assign(:findings, [])
      |> assign(:findings_page, empty_page())
      |> load_events()
      |> reload_dashboard()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = merge_filters(@empty_filters, params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> reload_dashboard()}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:filters, merge_filters(@empty_filters, filters))
     |> assign(:findings_page, empty_page())
     |> reload_dashboard()}
  end

  def handle_event("apply_filters", _params, socket) do
    {:noreply, push_patch(socket, to: filter_path(socket))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, @empty_filters)
     |> push_patch(to: ~p"/admin/reconciliation")}
  end

  def handle_event("update_action_event", %{"action" => %{"event_id" => event_id}}, socket) do
    {:noreply,
     socket
     |> assign(:action_event_id, event_id || "")
     |> assign(:confirm_attendee_sync, false)
     |> assign(:confirm_reconciliation, false)}
  end

  def handle_event("confirm_attendee_sync", _params, socket) do
    {:noreply, assign(socket, :confirm_attendee_sync, true)}
  end

  def handle_event("confirm_reconciliation", _params, socket) do
    {:noreply, assign(socket, :confirm_reconciliation, true)}
  end

  def handle_event("queue_attendee_sync", _params, socket) do
    if socket.assigns.confirm_attendee_sync do
      queue_attendee_sync(socket)
    else
      {:noreply, assign(socket, :confirm_attendee_sync, true)}
    end
  end

  def handle_event("queue_reconciliation", _params, socket) do
    if socket.assigns.confirm_reconciliation do
      queue_reconciliation(socket)
    else
      {:noreply, assign(socket, :confirm_reconciliation, true)}
    end
  end

  def handle_event("expand_finding", %{"id" => id}, socket) do
    if socket.assigns.expanded_finding_id == id do
      {:noreply,
       socket
       |> assign(:expanded_finding_id, nil)
       |> assign(:expanded_finding, nil)
       |> assign(:resolution_note, "")}
    else
      case AdminReconciliationDashboard.get_finding(id,
             actor: socket.assigns.current_user
           ) do
        {:ok, row} ->
          {:noreply,
           socket
           |> assign(:expanded_finding_id, id)
           |> assign(:expanded_finding, row)
           |> assign(:resolution_note, row.resolution_reason || "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Finding could not be loaded")}
      end
    end
  end

  def handle_event("update_resolution_note", %{"resolution" => %{"note" => note}}, socket) do
    {:noreply, assign(socket, :resolution_note, note)}
  end

  def handle_event("resolve_finding", %{"id" => id}, socket) do
    attrs = %{resolution_reason: String.trim(socket.assigns.resolution_note)}

    case AdminReconciliationDashboard.resolve_finding(id, attrs,
           actor: socket.assigns.current_user
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Finding marked resolved")
         |> assign(:expanded_finding_id, nil)
         |> assign(:expanded_finding, nil)
         |> reload_dashboard()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Finding could not be resolved")}
    end
  end

  def handle_event("ignore_finding", %{"id" => id}, socket) do
    attrs = %{resolution_reason: String.trim(socket.assigns.resolution_note)}

    case AdminReconciliationDashboard.ignore_finding(id, attrs,
           actor: socket.assigns.current_user
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Finding marked ignored")
         |> assign(:expanded_finding_id, nil)
         |> assign(:expanded_finding, nil)
         |> reload_dashboard()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Finding could not be ignored")}
    end
  end

  def handle_event("reopen_finding", %{"id" => id}, socket) do
    case AdminReconciliationDashboard.reopen_finding(id, actor: socket.assigns.current_user) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Finding reopened")
         |> assign(:expanded_finding_id, nil)
         |> assign(:expanded_finding, nil)
         |> reload_dashboard()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Finding could not be reopened")}
    end
  end

  def handle_event("findings_next_page", _params, socket) do
    {:noreply, load_findings(socket, socket.assigns.findings_page.page + 1)}
  end

  def handle_event("findings_previous_page", _params, socket) do
    {:noreply, load_findings(socket, max(socket.assigns.findings_page.page - 1, 1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-7xl px-6 py-8">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-zinc-900">Reconciliation</h1>
        <p class="text-sm text-zinc-600">
          Review Tickera/Woo findings from durable local snapshots. No live API calls from this page.
        </p>
      </div>

      <section class="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div class="rounded border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase text-zinc-500">Open findings</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900">{@snapshot.open_count}</p>
        </div>
        <div class="rounded border border-red-200 bg-red-50 p-4">
          <p class="text-xs font-semibold uppercase text-red-700">Critical</p>
          <p class="mt-1 text-2xl font-semibold text-red-900">{@snapshot.critical_count}</p>
        </div>
        <div class="rounded border border-amber-200 bg-amber-50 p-4">
          <p class="text-xs font-semibold uppercase text-amber-700">Warning</p>
          <p class="mt-1 text-2xl font-semibold text-amber-900">{@snapshot.warning_count}</p>
        </div>
        <div class="rounded border border-sky-200 bg-sky-50 p-4">
          <p class="text-xs font-semibold uppercase text-sky-700">Info</p>
          <p class="mt-1 text-2xl font-semibold text-sky-900">{@snapshot.info_count}</p>
        </div>
      </section>

      <section class="mb-6 grid gap-4 md:grid-cols-2">
        <div class="rounded border border-zinc-200 bg-white p-4 text-sm text-zinc-700">
          <h2 class="mb-2 font-semibold text-zinc-900">Latest reconciliation run</h2>
          <%= if @snapshot.latest_reconciliation_run do %>
            <p>Status: {@snapshot.latest_reconciliation_run.status}</p>
            <p class="text-xs text-zinc-500">Run {@snapshot.latest_reconciliation_run.id}</p>
            <p class="text-xs text-zinc-500">
              {format_datetime(@snapshot.latest_reconciliation_run.inserted_at)}
            </p>
          <% else %>
            <p class="text-zinc-500">No runs yet</p>
          <% end %>
        </div>
        <div class="rounded border border-zinc-200 bg-white p-4 text-sm text-zinc-700">
          <h2 class="mb-2 font-semibold text-zinc-900">Latest Tickera attendee sync</h2>
          <%= if @snapshot.latest_attendee_sync_run do %>
            <p>Status: {@snapshot.latest_attendee_sync_run.status}</p>
            <p class="text-xs text-zinc-500">Run {@snapshot.latest_attendee_sync_run.id}</p>
            <p class="text-xs text-zinc-500">
              {format_datetime(@snapshot.latest_attendee_sync_run.inserted_at)}
            </p>
          <% else %>
            <p class="text-zinc-500">No sync runs yet</p>
          <% end %>
        </div>
      </section>

      <section class="mb-8 rounded border border-zinc-200 bg-white p-4">
        <h2 class="mb-3 text-base font-semibold text-zinc-900">Manual actions</h2>
        <p class="mb-3 text-sm text-zinc-600">
          Sync refreshes local Tickera snapshots. Reconciliation compares those snapshots to Woo/EventSales data.
        </p>
        <form phx-change="update_action_event" id="reconciliation-actions" class="mb-4 max-w-md">
          <label class="text-sm font-medium text-zinc-700">
            Event
            <select
              name="action[event_id]"
              class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
            >
              <option value="" selected={@action_event_id == ""}>Select event</option>
              <option
                :for={event <- @events}
                value={event.event_id}
                selected={@action_event_id == event.event_id}
              >
                {event.event_name}
              </option>
            </select>
          </label>
        </form>
        <div class="flex flex-wrap gap-2">
          <button
            :if={!@confirm_attendee_sync}
            type="button"
            phx-click="confirm_attendee_sync"
            class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800"
          >
            Sync Tickera attendees
          </button>
          <button
            :if={@confirm_attendee_sync}
            type="button"
            phx-click="queue_attendee_sync"
            class="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm font-medium text-amber-900"
          >
            Confirm sync snapshots
          </button>
          <button
            :if={!@confirm_reconciliation}
            type="button"
            phx-click="confirm_reconciliation"
            class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800"
          >
            Run reconciliation
          </button>
          <button
            :if={@confirm_reconciliation}
            type="button"
            phx-click="queue_reconciliation"
            class="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm font-medium text-red-800"
          >
            Confirm reconciliation
          </button>
          <a
            href={export_href(@filters)}
            class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800"
          >
            Export CSV
          </a>
        </div>
      </section>

      <section class="mb-6 rounded border border-zinc-200 bg-white p-4">
        <h2 class="mb-3 text-base font-semibold text-zinc-900">Filters</h2>
        <.form
          for={%{}}
          as={:filters}
          phx-change="update_filters"
          phx-submit="apply_filters"
          id="finding-filters"
        >
          <div class="grid gap-3 md:grid-cols-3">
            <label class="text-sm font-medium text-zinc-700">
              Event
              <select
                name="filters[event_id]"
                class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option value="" selected={@filters["event_id"] == ""}>All</option>
                <option
                  :for={event <- @events}
                  value={event.event_id}
                  selected={@filters["event_id"] == event.event_id}
                >
                  {event.event_name}
                </option>
              </select>
            </label>
            <label class="text-sm font-medium text-zinc-700">
              Status
              <select
                name="filters[status]"
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              >
                <option value="" selected={@filters["status"] == ""}>All</option>
                <option value="open" selected={@filters["status"] == "open"}>open</option>
                <option value="resolved" selected={@filters["status"] == "resolved"}>resolved</option>
                <option value="ignored" selected={@filters["status"] == "ignored"}>ignored</option>
              </select>
            </label>
            <label class="text-sm font-medium text-zinc-700">
              Severity
              <select
                name="filters[severity]"
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              >
                <option value="" selected={@filters["severity"] == ""}>All</option>
                <option value="critical" selected={@filters["severity"] == "critical"}>
                  critical
                </option>
                <option value="warning" selected={@filters["severity"] == "warning"}>warning</option>
                <option value="info" selected={@filters["severity"] == "info"}>info</option>
              </select>
            </label>
            <label class="text-sm font-medium text-zinc-700 md:col-span-2">
              Finding type
              <input
                name="filters[finding_type]"
                value={@filters["finding_type"]}
                placeholder="e.g. woo_paid_missing_tickera"
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              />
            </label>
            <label class="text-sm font-medium text-zinc-700">
              Run ID
              <input
                name="filters[tickera_reconciliation_run_id]"
                value={@filters["tickera_reconciliation_run_id"]}
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              />
            </label>
            <label class="text-sm font-medium text-zinc-700">
              Last seen from
              <input
                type="date"
                name="filters[last_seen_from]"
                value={@filters["last_seen_from"]}
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              />
            </label>
            <label class="text-sm font-medium text-zinc-700">
              Last seen to
              <input
                type="date"
                name="filters[last_seen_to]"
                value={@filters["last_seen_to"]}
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              />
            </label>
          </div>
          <div class="mt-4 flex gap-2">
            <button type="submit" class="rounded bg-zinc-900 px-3 py-2 text-sm font-medium text-white">
              Apply filters
            </button>
            <button
              type="button"
              phx-click="clear_filters"
              class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800"
            >
              Clear
            </button>
          </div>
        </.form>
      </section>

      <section class="mb-8 overflow-x-auto border border-zinc-200">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Severity</th>
              <th class="px-3 py-2">Type</th>
              <th class="px-3 py-2">Event</th>
              <th class="px-3 py-2">Woo</th>
              <th class="px-3 py-2">Tickera</th>
              <th class="px-3 py-2">Last seen</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 bg-white" id="findings-table">
            <%= for row <- @findings do %>
              <tr id={"finding-#{row.id}"}>
                <td class="px-3 py-2">
                  <span class={severity_class(row.severity)}>{row.severity}</span>
                </td>
                <td class="px-3 py-2 text-zinc-700">{row.finding_type_label}</td>
                <td class="px-3 py-2 text-zinc-700">{row.event_name || row.event_id}</td>
                <td class="px-3 py-2 text-xs text-zinc-700">
                  <div>{row.woo_quantity}</div>
                  <div class="text-zinc-500">{row.woo_order_status}</div>
                  <div :if={row.woo_order_id} class="text-zinc-500">Order #{row.woo_order_id}</div>
                </td>
                <td class="px-3 py-2 text-xs text-zinc-700">
                  <div>{row.tickera_quantity}</div>
                  <div class="text-zinc-500">{row.tickera_payment_status}</div>
                  <div :if={row.ticket_code} class="text-zinc-500">{row.ticket_code}</div>
                </td>
                <td class="whitespace-nowrap px-3 py-2 text-zinc-700">
                  {format_datetime(row.last_seen_at)}
                </td>
                <td class="px-3 py-2">
                  <span class={status_class(row.status)}>{row.status}</span>
                </td>
                <td class="px-3 py-2">
                  <button
                    type="button"
                    phx-click="expand_finding"
                    phx-value-id={row.id}
                    class="text-xs font-medium text-sky-700 hover:underline"
                  >
                    {if @expanded_finding_id == row.id, do: "Hide", else: "Details"}
                  </button>
                </td>
              </tr>
              <%= if @expanded_finding_id == row.id && @expanded_finding do %>
                <tr id={"finding-expanded-#{row.id}"}>
                  <td colspan="8" class="bg-zinc-50 px-4 py-4 text-sm text-zinc-700">
                    <p class="font-medium text-zinc-900">{@expanded_finding.recommended_action}</p>
                    <p class="mt-2 text-xs text-zinc-500">
                      Run {@expanded_finding.tickera_reconciliation_run_id}
                    </p>
                    <pre
                      :if={map_size(@expanded_finding.details) > 0}
                      class="mt-2 overflow-x-auto rounded bg-white p-2 text-xs"
                    >{Jason.encode!(@expanded_finding.details, pretty: true)}</pre>
                    <.form
                      for={%{}}
                      as={:resolution}
                      phx-change="update_resolution_note"
                      id={"resolution-form-#{row.id}"}
                      class="mt-3"
                    >
                      <label class="block text-sm font-medium text-zinc-700">
                        Resolution note
                        <input
                          type="text"
                          name="resolution[note]"
                          value={@resolution_note}
                          class="mt-1 w-full max-w-xl rounded border border-zinc-300 px-3 py-2 text-sm"
                        />
                      </label>
                    </.form>
                    <div class="mt-3 flex flex-wrap gap-2">
                      <button
                        type="button"
                        phx-click="resolve_finding"
                        phx-value-id={@expanded_finding.id}
                        class="rounded border border-green-300 bg-green-50 px-3 py-1 text-sm text-green-800"
                      >
                        Mark resolved
                      </button>
                      <button
                        type="button"
                        phx-click="ignore_finding"
                        phx-value-id={@expanded_finding.id}
                        class="rounded border border-zinc-300 bg-white px-3 py-1 text-sm text-zinc-800"
                      >
                        Mark ignored
                      </button>
                      <button
                        type="button"
                        phx-click="reopen_finding"
                        phx-value-id={@expanded_finding.id}
                        class="rounded border border-amber-300 bg-amber-50 px-3 py-1 text-sm text-amber-800"
                      >
                        Reopen
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </section>

      <div class="flex items-center justify-between">
        <button
          type="button"
          phx-click="findings_previous_page"
          disabled={!@findings_page.has_previous?}
          class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm disabled:opacity-40"
        >
          Previous
        </button>
        <span class="text-sm text-zinc-600">Page {@findings_page.page}</span>
        <button
          type="button"
          phx-click="findings_next_page"
          disabled={!@findings_page.has_next?}
          class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm disabled:opacity-40"
        >
          Next
        </button>
      </div>
    </main>
    """
  end

  defp queue_attendee_sync(socket) do
    with {:ok, event_id} <- action_event_id(socket),
         :ok <- rate_limit(socket, :reconciliation_attendee_sync),
         {:ok, _result} <-
           AdminReconciliationDashboard.queue_attendee_sync(event_id,
             actor: socket.assigns.current_user,
             audit_attrs: audit_attrs(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Tickera attendee sync queued (refreshes local snapshots)")
       |> assign(:confirm_attendee_sync, false)
       |> reload_dashboard()}
    else
      {:error, :missing_event} ->
        {:noreply, put_flash(socket, :error, "Select an event first")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Try again shortly")}

      {:error, :inactive_source} ->
        {:noreply, put_flash(socket, :error, "Tickera source is inactive for this event")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No active Tickera source for this event")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Sync could not be queued")}
    end
  end

  defp queue_reconciliation(socket) do
    with {:ok, event_id} <- action_event_id(socket),
         :ok <- rate_limit(socket, :reconciliation_run),
         {:ok, _result} <-
           AdminReconciliationDashboard.queue_reconciliation(event_id,
             actor: socket.assigns.current_user,
             audit_attrs: audit_attrs(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Reconciliation queued (compares local snapshots)")
       |> assign(:confirm_reconciliation, false)
       |> reload_dashboard()}
    else
      {:error, :missing_event} ->
        {:noreply, put_flash(socket, :error, "Select an event first")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Try again shortly")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Event not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Reconciliation could not be queued")}
    end
  end

  defp action_event_id(socket) do
    case socket.assigns.action_event_id do
      event_id when event_id in [nil, ""] -> {:error, :missing_event}
      event_id -> {:ok, event_id}
    end
  end

  defp rate_limit(socket, action) do
    case ManualActionRateLimiter.allow?(socket.assigns.current_user_id, action) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp reload_dashboard(socket) do
    socket
    |> load_snapshot()
    |> load_runs()
    |> load_findings(socket.assigns.findings_page.page)
  end

  defp load_snapshot(socket) do
    opts = dashboard_opts(socket)

    case AdminReconciliationDashboard.snapshot(opts) do
      {:ok, snapshot} -> assign(socket, :snapshot, snapshot)
      {:error, _} -> assign(socket, :snapshot, empty_snapshot())
    end
  end

  defp load_runs(socket) do
    case AdminReconciliationDashboard.list_runs(
           dashboard_opts(socket)
           |> Keyword.put(:per_page, 5)
         ) do
      {:ok, %{rows: rows}} -> assign(socket, :runs, rows)
      {:error, _} -> assign(socket, :runs, [])
    end
  end

  defp load_findings(socket, page) do
    opts =
      dashboard_opts(socket)
      |> Keyword.put(:page, page)

    case AdminReconciliationDashboard.list_findings(opts) do
      {:ok, %{rows: rows, page: page_info}} ->
        socket
        |> assign(:findings, rows)
        |> assign(:findings_page, page_info)

      {:error, _} ->
        socket
        |> assign(:findings, [])
        |> assign(:findings_page, empty_page())
        |> put_flash(:error, "Findings could not be loaded")
    end
  end

  defp load_events(socket) do
    case EventDetail.list_events(actor: socket.assigns.current_user, page: 1, per_page: 50) do
      {:ok, %{rows: rows}} -> assign(socket, :events, rows)
      {:error, _} -> assign(socket, :events, [])
    end
  end

  defp dashboard_opts(socket) do
    filters = socket.assigns.filters

    [
      event_id: filters["event_id"],
      tickera_event_source_id: filters["tickera_event_source_id"],
      tickera_reconciliation_run_id: filters["tickera_reconciliation_run_id"],
      ticket_type_id: filters["ticket_type_id"],
      status: filters["status"],
      severity: filters["severity"],
      finding_type: filters["finding_type"],
      woo_order_status: filters["woo_order_status"],
      tickera_payment_status: filters["tickera_payment_status"],
      last_seen_from: filters["last_seen_from"],
      last_seen_to: filters["last_seen_to"],
      actor: socket.assigns.current_user
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  defp filter_path(socket) do
    query =
      socket.assigns.filters
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    if query == "", do: ~p"/admin/reconciliation", else: ~p"/admin/reconciliation?#{query}"
  end

  defp export_href(filters) do
    query =
      filters
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    if query == "",
      do: "/admin/reconciliation/export.csv",
      else: "/admin/reconciliation/export.csv?" <> query
  end

  defp audit_attrs(socket) do
    %{
      actor_type: :user,
      actor_user_id: socket.assigns.current_user.id,
      actor_role: :admin,
      source: :admin
    }
  end

  defp merge_filters(defaults, params) do
    params =
      case params do
        %{"filters" => nested} when is_map(nested) -> nested
        other -> other
      end

    Map.merge(defaults, Map.take(params, Map.keys(defaults)))
  end

  defp severity_class(:critical),
    do: "rounded bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800"

  defp severity_class(:warning),
    do: "rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800"

  defp severity_class(:info),
    do: "rounded bg-sky-100 px-2 py-0.5 text-xs font-medium text-sky-800"

  defp severity_class(_), do: "rounded bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700"

  defp status_class(:open),
    do: "rounded bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-800"

  defp status_class(:resolved),
    do: "rounded bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800"

  defp status_class(:ignored),
    do: "rounded bg-zinc-200 px-2 py-0.5 text-xs font-medium text-zinc-600"

  defp status_class(_), do: "rounded bg-zinc-100 px-2 py-0.5 text-xs text-zinc-700"

  defp current_user(%{"current_user_id" => user_id}) when is_binary(user_id) do
    case Ash.get(User, user_id, domain: Accounts) do
      {:ok, %User{active: true} = user} -> user
      _ -> nil
    end
  end

  defp current_user(_), do: nil

  defp current_user_id(%{"current_user_id" => user_id}) when is_binary(user_id), do: user_id
  defp current_user_id(%{current_user_id: user_id}) when is_binary(user_id), do: user_id
  defp current_user_id(_), do: "unknown"

  defp empty_snapshot do
    %{
      open_count: 0,
      critical_count: 0,
      warning_count: 0,
      info_count: 0,
      latest_reconciliation_run: nil,
      latest_attendee_sync_run: nil,
      scoped_event_id: nil
    }
  end

  defp empty_page, do: %{page: 1, per_page: 25, has_next?: false, has_previous?: false}

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
end
