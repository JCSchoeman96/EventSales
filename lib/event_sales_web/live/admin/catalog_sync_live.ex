defmodule EventSalesWeb.Live.Admin.CatalogSyncLive do
  @moduledoc """
  Admin Tickera catalog dry-run/apply UI.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @empty_form %{
    "source_system_id" => "",
    "scope_kind" => "woo_product",
    "manual_rows" => ""
  }

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Catalog Sync")
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:form, @empty_form)
      |> assign(:source_systems, [])
      |> assign(:runs, [])
      |> assign(:previews, %{})
      |> load_source_systems()
      |> load_runs()

    {:ok, socket}
  end

  @impl true
  def handle_event("update_form", %{"catalog_sync" => form}, socket) do
    {:noreply, assign(socket, :form, normalize_form(form))}
  end

  def handle_event("queue_dry_run", %{"catalog_sync" => form}, socket) do
    form = normalize_form(form)

    with {:ok, scope} <- build_scope(form),
         {:ok, %{run: _run}} <-
           TickeraCatalogSync.queue_dry_run(
             %{source_system_id: form["source_system_id"], scope: scope},
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Catalog dry-run queued")
       |> assign(:form, form)
       |> load_runs()}
    else
      {:error, :invalid_manual_rows} ->
        {:noreply, put_flash(socket, :error, "Manual rows must be valid JSON")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to run catalog sync")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Catalog dry-run could not be queued")}
    end
  end

  def handle_event("queue_apply", %{"run_id" => run_id, "dry_run_hash" => dry_run_hash}, socket) do
    case TickeraCatalogSync.queue_apply(run_id, dry_run_hash, actor: socket.assigns.current_user) do
      {:ok, _queued} ->
        {:noreply,
         socket
         |> put_flash(:info, "Catalog apply queued")
         |> load_runs()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to apply catalog sync")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Catalog apply could not be queued")}
    end
  end

  @impl true
  def handle_info({event, %{run_id: _run_id}}, socket)
      when event in [
             :catalog_sync_started,
             :catalog_sync_preview_ready,
             :catalog_sync_failed,
             :catalog_sync_applied
           ] do
    {:noreply, load_runs(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/catalog-sync"
      page_title="Catalog Sync"
      page_description="Dry-run publish-only Tickera Bridge catalog rows before apply."
    >
      <section class="card mb-8 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="mb-4 text-base font-semibold text-zinc-900">Run Tickera catalog dry-run</h2>
          <form
            id="catalog-sync-form"
            phx-change="update_form"
            phx-submit="queue_dry_run"
            class="grid gap-4"
          >
            <label class="text-sm font-medium text-zinc-700">
              Source system
              <select
                name="catalog_sync[source_system_id]"
                class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option value="" selected={@form["source_system_id"] == ""}>Select source</option>
                <option
                  :for={source <- @source_systems}
                  value={source.id}
                  selected={@form["source_system_id"] == source.id}
                >
                  {source.name}
                </option>
              </select>
            </label>

            <label class="text-sm font-medium text-zinc-700">
              Scope
              <select
                name="catalog_sync[scope_kind]"
                class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option value="woo_product" selected={@form["scope_kind"] == "woo_product"}>
                  VWG Pretoria pilot product 109740
                </option>
                <option value="tickera_event" selected={@form["scope_kind"] == "tickera_event"}>
                  VWG Pretoria Tickera event 109316
                </option>
                <option
                  value="all_published_tickera"
                  selected={@form["scope_kind"] == "all_published_tickera"}
                >
                  All published Tickera events
                </option>
              </select>
            </label>

            <label class="text-sm font-medium text-zinc-700">
              Sanitized manual export rows JSON <textarea
                name="catalog_sync[manual_rows]"
                rows="8"
                class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 font-mono text-xs"
              >{@form["manual_rows"]}</textarea>
            </label>

            <div>
              <button
                type="submit"
                class="rounded border border-zinc-900 bg-zinc-900 px-3 py-2 text-sm font-medium text-white"
              >
                Queue dry-run
              </button>
            </div>
          </form>
        </div>
      </section>

      <section class="overflow-x-auto border border-zinc-200 bg-white">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Queued</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Hash</th>
              <th class="px-3 py-2">Summary</th>
              <th class="px-3 py-2">Action</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 bg-white">
            <tr :for={run <- @runs}>
              <td class="px-3 py-2 text-zinc-700">{format_datetime(run.inserted_at)}</td>
              <td class="px-3 py-2 text-zinc-700">{run.status}</td>
              <td class="px-3 py-2 font-mono text-xs text-zinc-700">{run.dry_run_hash || "-"}</td>
              <td class="px-3 py-2 text-xs text-zinc-700">{summary_text(run.summary)}</td>
              <td class="px-3 py-2">
                <button
                  type="button"
                  phx-click="queue_apply"
                  phx-value-run_id={run.id}
                  phx-value-dry_run_hash={run.dry_run_hash}
                  disabled={!apply_enabled?(run, preview(@previews, run.id))}
                  class="rounded border border-zinc-900 bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white disabled:cursor-not-allowed disabled:border-zinc-300 disabled:bg-zinc-200 disabled:text-zinc-500"
                >
                  Apply
                </button>
              </td>
            </tr>
            <tr :for={run <- @runs}>
              <td class="px-3 py-4" colspan="5">
                <div class="space-y-4">
                  <div :if={findings(preview(@previews, run.id)) != []}>
                    <h3 class="mb-2 text-xs font-semibold uppercase text-zinc-600">Findings</h3>
                    <ul class="space-y-2">
                      <li
                        :for={finding <- findings(preview(@previews, run.id))}
                        class="rounded border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-700"
                      >
                        <span class="font-semibold">{value(finding, "severity")}</span>
                        <span class="font-mono">{value(finding, "code")}</span>
                        <span>{value(finding, "message")}</span>
                      </li>
                    </ul>
                  </div>

                  <div :if={preview_event_groups(preview(@previews, run.id)) != []}>
                    <h3 class="mb-2 text-xs font-semibold uppercase text-zinc-600">
                      Proposed Catalog Changes
                    </h3>
                    <div class="space-y-3">
                      <div
                        :for={group <- preview_event_groups(preview(@previews, run.id))}
                        class="rounded border border-zinc-200 px-3 py-2"
                      >
                        <div class="text-sm font-medium text-zinc-900">{group.event_label}</div>
                        <div class="mt-2 grid gap-2 text-xs text-zinc-700 md:grid-cols-3">
                          <div>
                            <div class="font-semibold uppercase text-zinc-500">Event</div>
                            <div :for={change <- group.event_changes}>
                              {value(change, "action")} Tickera event {value(
                                change,
                                "external_event_id"
                              ) ||
                                value(change, "event_id")}
                            </div>
                          </div>
                          <div>
                            <div class="font-semibold uppercase text-zinc-500">Ticket Types</div>
                            <div :for={change <- group.ticket_type_changes}>
                              {value(change, "action")} {value(change, "name") ||
                                value(change, "external_ticket_type_id")}
                            </div>
                          </div>
                          <div>
                            <div class="font-semibold uppercase text-zinc-500">Mappings</div>
                            <div :for={change <- group.product_mapping_changes}>
                              {value(change, "action")} product {value(change, "woo_product_id")}
                              <span :if={value(change, "woo_variation_id")}>
                                / variation {value(change, "woo_variation_id")}
                              </span>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </td>
            </tr>
            <tr :if={@runs == []}>
              <td class="px-3 py-6 text-center text-zinc-500" colspan="5">
                No catalog sync runs yet.
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </AdminShell.shell>
    """
  end

  defp build_scope(%{"manual_rows" => manual_rows, "scope_kind" => kind}) do
    with {:ok, decoded} <- decode_manual_rows(manual_rows) do
      {:ok,
       decoded
       |> Map.put("kind", "manual_rows")
       |> Map.put("requested_scope", pilot_scope(kind))}
    end
  end

  defp decode_manual_rows(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:ok, %{"events" => [], "catalog_rows" => []}}
    else
      case Jason.decode(value) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _other -> {:error, :invalid_manual_rows}
      end
    end
  end

  defp pilot_scope("tickera_event"),
    do: %{"kind" => "tickera_event", "tickera_event_id" => 109_316}

  defp pilot_scope("all_published_tickera"), do: %{"kind" => "all_published_tickera"}
  defp pilot_scope(_kind), do: %{"kind" => "woo_product", "woo_product_id" => 109_740}

  defp normalize_form(form), do: Map.merge(@empty_form, Map.take(form, Map.keys(@empty_form)))

  defp load_source_systems(socket) do
    case TickeraCatalogSync.list_source_systems(actor: socket.assigns.current_user) do
      {:ok, source_systems} -> assign(socket, :source_systems, source_systems)
      {:error, _reason} -> assign(socket, :source_systems, [])
    end
  end

  defp load_runs(socket) do
    case TickeraCatalogSync.list_runs(actor: socket.assigns.current_user) do
      {:ok, runs} ->
        socket
        |> subscribe_runs(runs)
        |> assign(:runs, runs)
        |> assign(:previews, load_previews(runs, socket.assigns.current_user))

      {:error, _reason} ->
        assign(socket, :runs, [])
    end
  end

  defp load_previews(runs, current_user) do
    Map.new(runs, fn run ->
      preview =
        case TickeraCatalogSync.get_run_preview(run.id, actor: current_user) do
          {:ok, %{preview: preview}} when is_map(preview) -> preview
          _other -> %{}
        end

      {run.id, preview}
    end)
  end

  defp subscribe_runs(socket, runs) do
    if connected?(socket) do
      Enum.each(runs, &PubSub.subscribe(&1.id))
    end

    socket
  end

  defp preview(previews, run_id), do: Map.get(previews, run_id, %{})

  defp apply_enabled?(run, preview) do
    run.status == :dry_run_ready and is_binary(run.dry_run_hash) and
      not blocking_findings?(preview)
  end

  defp blocking_findings?(preview) do
    Enum.any?(findings(preview), &(value(&1, "severity") in [:blocking, "blocking"]))
  end

  defp findings(preview), do: list(preview, "findings")

  defp preview_event_groups(preview) do
    event_changes = list(preview, "event_changes")
    ticket_changes = list(preview, "ticket_type_changes")
    mapping_changes = list(preview, "product_mapping_changes")

    Enum.map(event_changes, fn event_change ->
      event_ref = value(event_change, "ref")

      %{
        event_label:
          "Tickera event #{value(event_change, "external_event_id") || value(event_change, "event_id")}",
        event_changes: [event_change],
        ticket_type_changes:
          Enum.filter(ticket_changes, fn change ->
            is_nil(event_ref) or value(change, "event_ref") == event_ref or
              value(change, "event_id") == value(event_change, "event_id")
          end),
        product_mapping_changes:
          Enum.filter(mapping_changes, fn change ->
            is_nil(event_ref) or value(change, "event_ref") == event_ref
          end)
      }
    end)
  end

  defp list(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp summary_text(summary) when is_map(summary) and map_size(summary) > 0 do
    Enum.map_join(summary, ", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp summary_text(_summary), do: "-"

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
