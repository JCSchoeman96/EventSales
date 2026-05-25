defmodule EventSalesWeb.Live.Admin.ImportsLive do
  @moduledoc """
  Admin CSV import dry-run UI.

  This LiveView stays thin: CSV parsing and validation are delegated to the
  ingestion facade.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Analytics.EventDetail
  alias EventSales.Ingestion.CsvImports
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @impl true
  def mount(params, session, socket) do
    selected_event_id = Map.get(params, "event_id", "")

    socket =
      socket
      |> assign(:page_title, "CSV Imports")
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:selected_event_id, selected_event_id)
      |> assign(:events, [])
      |> assign(:batches, [])
      |> assign(:latest_batch, nil)
      |> assign(:rows, [])
      |> allow_upload(:csv, accept: ~w(.csv), max_entries: 1, max_file_size: 10_000_000)
      |> load_events()
      |> load_batches()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_event", %{"import" => %{"event_id" => event_id}}, socket) do
    {:noreply, assign(socket, :selected_event_id, event_id)}
  end

  def handle_event("dry_run", %{"import" => %{"event_id" => event_id}}, socket) do
    socket = assign(socket, :selected_event_id, event_id)

    case consume_csv_upload(socket, event_id) do
      {:ok, batch} ->
        message =
          if batch.status == :dry_run_passed do
            "Dry-run passed"
          else
            "Dry-run found errors"
          end

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(:latest_batch, batch)
         |> load_rows(batch.id)
         |> load_batches()}

      {:error, :event_required} ->
        {:noreply, put_flash(socket, :error, "Select an event before uploading a CSV")}

      {:error, :no_upload} ->
        {:noreply, put_flash(socket, :error, "Choose a CSV file before running dry-run")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "CSV dry-run could not be completed")}
    end
  end

  def handle_event("apply", %{"batch_id" => batch_id}, socket) do
    case CsvImports.queue_apply(batch_id, actor: socket.assigns.current_user) do
      {:ok, %{batch: batch}} ->
        {:noreply,
         socket
         |> put_flash(:info, "CSV apply queued")
         |> assign(:latest_batch, batch)
         |> load_rows(batch.id)
         |> load_batches()}

      {:error, :empty_batch} ->
        {:noreply, put_flash(socket, :error, "CSV import has no valid rows to apply")}

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Only passed dry-runs can be applied")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to apply imports")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "CSV apply could not be queued")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/imports"
      page_title="CSV Imports"
      page_description="Dry-run validation for event-scoped order line CSVs."
    >
      <section class="card mb-8 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="mb-4 text-base font-semibold text-zinc-900">Run dry-run</h2>
          <form
            id="csv-import-form"
            phx-change="select_event"
            phx-submit="dry_run"
            phx-drop-target={@uploads.csv.ref}
            class="grid gap-4"
          >
            <label class="text-sm font-medium text-zinc-700">
              Event
              <select
                name="import[event_id]"
                class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
              >
                <option value="" selected={@selected_event_id == ""}>Select event</option>
                <option
                  :for={event <- @events}
                  value={event.event_id}
                  selected={@selected_event_id == event.event_id}
                >
                  {event.event_name}
                </option>
              </select>
            </label>

            <div>
              <.live_file_input
                upload={@uploads.csv}
                class="block w-full rounded border border-zinc-300 px-3 py-2 text-sm"
              />
              <div class="mt-2 text-sm text-zinc-600">
                <div :for={entry <- @uploads.csv.entries}>
                  <span>{entry.client_name}</span>
                  <span>{entry.progress}%</span>
                </div>
              </div>
            </div>

            <div>
              <button
                type="submit"
                class="rounded border border-zinc-900 bg-zinc-900 px-3 py-2 text-sm font-medium text-white"
              >
                Run dry-run
              </button>
            </div>
          </form>
        </div>
      </section>

      <section :if={@latest_batch} class="card mb-8 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="mb-3 text-base font-semibold text-zinc-900">Latest dry-run</h2>
          <div class="grid gap-3 text-sm sm:grid-cols-6">
            <div>
              <div class="text-xs font-semibold uppercase text-zinc-500">Status</div>
              <div class="text-zinc-900">{@latest_batch.status}</div>
            </div>
            <div>
              <div class="text-xs font-semibold uppercase text-zinc-500">Rows</div>
              <div class="text-zinc-900">{@latest_batch.row_count}</div>
            </div>
            <div>
              <div class="text-xs font-semibold uppercase text-zinc-500">Valid</div>
              <div class="text-zinc-900">{@latest_batch.valid_count}</div>
            </div>
            <div>
              <div class="text-xs font-semibold uppercase text-zinc-500">Errors</div>
              <div class="text-zinc-900">{@latest_batch.error_count}</div>
            </div>
            <div>
              <div class="text-xs font-semibold uppercase text-zinc-500">Duplicates</div>
              <div class="text-zinc-900">{@latest_batch.duplicate_count}</div>
            </div>
            <div :if={applyable?(@latest_batch)}>
              <div class="text-xs font-semibold uppercase text-zinc-500">Action</div>
              <button
                type="button"
                phx-click="apply"
                phx-value-batch_id={@latest_batch.id}
                class="mt-1 rounded border border-zinc-900 bg-zinc-900 px-3 py-2 text-sm font-medium text-white"
              >
                Apply import
              </button>
            </div>
          </div>
        </div>
      </section>

      <section :if={@rows != []} class="mb-8 overflow-x-auto border border-zinc-200">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Row</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Order</th>
              <th class="px-3 py-2">Line</th>
              <th class="px-3 py-2">Errors</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 bg-white">
            <tr :for={row <- @rows}>
              <td class="px-3 py-2 text-zinc-700">{row.row_number}</td>
              <td class="px-3 py-2 text-zinc-700">{row.status}</td>
              <td class="px-3 py-2 text-zinc-700">{row.external_order_number}</td>
              <td class="px-3 py-2 text-zinc-700">{line_id(row)}</td>
              <td class="px-3 py-2 text-red-700">{Enum.join(row.error_messages, ", ")}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="overflow-x-auto border border-zinc-200">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Uploaded</th>
              <th class="px-3 py-2">File</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Rows</th>
              <th class="px-3 py-2">Errors</th>
              <th class="px-3 py-2">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 bg-white">
            <tr :for={batch <- @batches}>
              <td class="px-3 py-2 text-zinc-700">{format_datetime(batch.inserted_at)}</td>
              <td class="px-3 py-2 text-zinc-700">{batch.source_filename}</td>
              <td class="px-3 py-2 text-zinc-700">{batch.status}</td>
              <td class="px-3 py-2 text-zinc-700">{batch.row_count}</td>
              <td class="px-3 py-2 text-zinc-700">{batch.error_count}</td>
              <td class="px-3 py-2 text-zinc-700">
                <button
                  :if={applyable?(batch)}
                  type="button"
                  phx-click="apply"
                  phx-value-batch_id={batch.id}
                  class="rounded border border-zinc-900 bg-zinc-900 px-3 py-1 text-xs font-medium text-white"
                >
                  Apply import
                </button>
              </td>
            </tr>
            <tr :if={@batches == []}>
              <td class="px-3 py-6 text-center text-zinc-500" colspan="6">No imports yet.</td>
            </tr>
          </tbody>
        </table>
      </section>
    </AdminShell.shell>
    """
  end

  defp consume_csv_upload(_socket, ""), do: {:error, :event_required}

  defp consume_csv_upload(socket, event_id) do
    results =
      consume_uploaded_entries(socket, :csv, fn %{path: path}, entry ->
        CsvImports.dry_run_file(
          path,
          %{event_id: event_id, source_filename: entry.client_name},
          actor: socket.assigns.current_user
        )
      end)

    case results do
      [%{status: _status} = batch] -> {:ok, batch}
      [{:error, reason}] -> {:error, reason}
      _other -> {:error, :no_upload}
    end
  end

  defp load_events(socket) do
    case EventDetail.list_events(actor: socket.assigns.current_user, page: 1, per_page: 50) do
      {:ok, %{rows: events}} -> assign(socket, :events, events)
      {:error, _reason} -> assign(socket, :events, [])
    end
  end

  defp load_batches(socket) do
    case CsvImports.list_batches(actor: socket.assigns.current_user) do
      {:ok, batches} -> assign(socket, :batches, batches)
      {:error, _reason} -> assign(socket, :batches, [])
    end
  end

  defp load_rows(socket, batch_id) do
    case CsvImports.list_rows(batch_id, actor: socket.assigns.current_user, limit: 200) do
      {:ok, rows} -> assign(socket, :rows, rows)
      {:error, _reason} -> assign(socket, :rows, [])
    end
  end

  defp line_id(row) do
    row.external_line_key
    |> to_string()
    |> String.split(":")
    |> List.last()
  end

  defp applyable?(%{status: :dry_run_passed, valid_count: valid_count}) when valid_count > 0,
    do: true

  defp applyable?(_batch), do: false

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
