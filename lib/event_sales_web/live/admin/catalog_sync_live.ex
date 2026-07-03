defmodule EventSalesWeb.Live.Admin.CatalogSyncLive do
  @moduledoc """
  Admin Tickera catalog dry-run/apply UI.
  """

  use EventSalesWeb, :live_view

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

      <section class="overflow-x-auto border border-zinc-200">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Queued</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Hash</th>
              <th class="px-3 py-2">Summary</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 bg-white">
            <tr :for={run <- @runs}>
              <td class="px-3 py-2 text-zinc-700">{format_datetime(run.inserted_at)}</td>
              <td class="px-3 py-2 text-zinc-700">{run.status}</td>
              <td class="px-3 py-2 font-mono text-xs text-zinc-700">{run.dry_run_hash || "-"}</td>
              <td class="px-3 py-2 text-xs text-zinc-700">{summary_text(run.summary)}</td>
            </tr>
            <tr :if={@runs == []}>
              <td class="px-3 py-6 text-center text-zinc-500" colspan="4">
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
      {:ok, runs} -> assign(socket, :runs, runs)
      {:error, _reason} -> assign(socket, :runs, [])
    end
  end

  defp summary_text(summary) when is_map(summary) and map_size(summary) > 0 do
    Enum.map_join(summary, ", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp summary_text(_summary), do: "-"

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
