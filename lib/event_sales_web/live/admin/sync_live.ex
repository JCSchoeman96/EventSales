defmodule EventSalesWeb.Live.Admin.SyncLive do
  @moduledoc """
  Admin manual reconciliation sync UI.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User
  alias EventSales.Analytics.EventDetail
  alias EventSales.Ingestion.{ManualSync, SyncDebug}
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  @empty_form %{
    "event_id" => "",
    "date_from" => "",
    "date_to" => "",
    "sync_mode" => "shallow"
  }

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Manual Sync")
      |> assign(:current_user, current_user(session))
      |> assign(:current_user_id, current_user_id(session))
      |> assign(:form, @empty_form)
      |> assign(:confirm_sync, false)
      |> assign(:events, [])
      |> assign(:page, empty_page())
      |> stream(:sync_runs, [])
      |> load_events()
      |> load_runs(1)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_form", %{"sync" => sync}, socket) do
    {:noreply,
     socket
     |> assign(:form, normalize_form(sync))
     |> assign(:confirm_sync, false)}
  end

  def handle_event("confirm_sync", _params, socket) do
    {:noreply, assign(socket, :confirm_sync, true)}
  end

  def handle_event("queue_sync", _params, socket) do
    if socket.assigns.confirm_sync do
      queue_confirmed(socket)
    else
      {:noreply, assign(socket, :confirm_sync, true)}
    end
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, load_runs(socket, socket.assigns.page.page + 1)}
  end

  def handle_event("previous_page", _params, socket) do
    {:noreply, load_runs(socket, max(socket.assigns.page.page - 1, 1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-7xl px-6 py-8">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-zinc-900">Manual Sync</h1>
        <p class="text-sm text-zinc-600">Scoped order reconciliation for one event.</p>
      </div>

      <section class="mb-8 rounded border border-zinc-200 bg-white p-4">
        <h2 class="mb-4 text-base font-semibold text-zinc-900">Queue scoped sync</h2>
        <form phx-change="update_form" id="sync-form" class="grid gap-3 md:grid-cols-2">
          <label class="text-sm font-medium text-zinc-700 md:col-span-2">
            Event
            <select
              name="sync[event_id]"
              class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
            >
              <option value="" selected={@form["event_id"] == ""}>Select event</option>
              <option
                :for={event <- @events}
                value={event.event_id}
                selected={@form["event_id"] == event.event_id}
              >
                {event.event_name}
              </option>
            </select>
          </label>
          <label class="text-sm font-medium text-zinc-700">
            Date from
            <input
              type="date"
              name="sync[date_from]"
              value={@form["date_from"]}
              class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
            />
          </label>
          <label class="text-sm font-medium text-zinc-700">
            Date to
            <input
              type="date"
              name="sync[date_to]"
              value={@form["date_to"]}
              class="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm"
            />
          </label>
          <label class="text-sm font-medium text-zinc-700 md:col-span-2">
            Sync mode
            <select
              name="sync[sync_mode]"
              class="mt-1 w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm"
            >
              <option value="shallow" selected={@form["sync_mode"] == "shallow"}>shallow</option>
              <option value="deep" selected={@form["sync_mode"] == "deep"}>deep</option>
            </select>
          </label>
        </form>
        <div class="mt-4 flex flex-wrap gap-2">
          <button
            :if={!@confirm_sync}
            type="button"
            phx-click="confirm_sync"
            class="rounded border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-800"
          >
            Queue sync
          </button>
          <button
            :if={@confirm_sync}
            type="button"
            phx-click="queue_sync"
            class="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm font-medium text-red-800"
          >
            Confirm sync
          </button>
        </div>
      </section>

      <section class="overflow-x-auto border border-zinc-200">
        <table class="min-w-full divide-y divide-zinc-200 text-sm">
          <thead class="bg-zinc-50 text-left text-xs font-semibold uppercase text-zinc-600">
            <tr>
              <th class="px-3 py-2">Queued</th>
              <th class="px-3 py-2">Via</th>
              <th class="px-3 py-2">Mode</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Range</th>
              <th class="px-3 py-2">Counts</th>
              <th class="px-3 py-2">Paused</th>
            </tr>
          </thead>
          <tbody id="sync-runs" phx-update="stream" class="divide-y divide-zinc-100 bg-white">
            <tr :for={{dom_id, run} <- @streams.sync_runs} id={dom_id}>
              <td class="whitespace-nowrap px-3 py-2 text-zinc-700">
                {format_datetime(run.inserted_at)}
              </td>
              <td class="px-3 py-2 text-zinc-700">{run.requested_via}</td>
              <td class="px-3 py-2 text-zinc-700">{run.sync_mode}</td>
              <td class="px-3 py-2 text-zinc-700">{run.status}</td>
              <td class="px-3 py-2 text-zinc-700">
                <div>{format_datetime(run.date_from)}</div>
                <div class="text-xs text-zinc-500">{format_datetime(run.date_to)}</div>
              </td>
              <td class="px-3 py-2 text-xs text-zinc-700">
                <div>seen {run.orders_seen_count}</div>
                <div>matched {run.orders_matched_count}</div>
                <div>upserted {run.orders_upserted_count}</div>
                <div>failed {run.orders_failed_count}</div>
                <div>errors {run.errors_count}</div>
              </td>
              <td class="px-3 py-2 text-zinc-700">
                <div :if={run.paused_until}>{format_datetime(run.paused_until)}</div>
                <div :if={run.pause_reason} class="text-xs text-zinc-500">{run.pause_reason}</div>
                <div :if={run.last_error} class="mt-1 max-w-xs truncate text-xs text-red-700">
                  {run.last_error}
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

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
    </main>
    """
  end

  defp queue_confirmed(socket) do
    case ManualActionRateLimiter.allow?(socket.assigns.current_user_id, :manual_sync) do
      :ok ->
        with {:ok, run_attrs} <- build_run_attrs(socket),
             {:ok, %{sync_run: _run}} <-
               ManualSync.queue_manual_scoped(
                 run_attrs,
                 audit_attrs(socket),
                 actor: socket.assigns.current_user
               ) do
          {:noreply,
           socket
           |> put_flash(:info, "Sync queued")
           |> assign(:confirm_sync, false)
           |> load_runs(socket.assigns.page.page)}
        else
          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Sync is not allowed")}

          {:error, :enqueue_failed} ->
            {:noreply,
             socket
             |> put_flash(:error, "Sync could not be queued. Try again.")
             |> assign(:confirm_sync, false)}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(:error, scope_error_message())
             |> assign(:confirm_sync, false)}
        end

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Try again shortly")}
    end
  end

  defp build_run_attrs(socket) do
    form = socket.assigns.form

    with {:ok, %{source_system_id: source_system_id, event_id: event_id}} <-
           SyncDebug.event_scope(form["event_id"], actor: socket.assigns.current_user),
         {:ok, date_from} <- parse_date(form["date_from"], :start_of_day),
         {:ok, date_to} <- parse_date(form["date_to"], :end_of_day),
         {:ok, sync_mode} <- parse_sync_mode(form["sync_mode"]) do
      {:ok,
       %{
         source_system_id: source_system_id,
         event_id: event_id,
         date_from: date_from,
         date_to: date_to,
         sync_mode: sync_mode
       }}
    else
      {:error, :not_found} -> {:error, :invalid_scope}
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp audit_attrs(socket) do
    %{
      actor_type: :user,
      actor_user_id: socket.assigns.current_user.id,
      actor_role: :admin,
      source: :admin
    }
  end

  defp parse_date(value, boundary) when is_binary(value) do
    value = String.trim(value)

    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, datetime} <- boundary_datetime(date, boundary) do
      {:ok, datetime}
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_value, _boundary), do: {:error, :invalid_date}

  defp boundary_datetime(date, :start_of_day) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    |> then(&{:ok, &1})
  rescue
    _ -> {:error, :invalid_date}
  end

  defp boundary_datetime(date, :end_of_day) do
    DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
    |> then(&{:ok, &1})
  rescue
    _ -> {:error, :invalid_date}
  end

  defp parse_sync_mode("shallow"), do: {:ok, :shallow}
  defp parse_sync_mode("deep"), do: {:ok, :deep}
  defp parse_sync_mode(_mode), do: {:error, :invalid_sync_mode}

  defp scope_error_message do
    "Sync requires an event and a valid date range (date to must be after date from)."
  end

  defp load_events(socket) do
    case EventDetail.list_events(actor: socket.assigns.current_user, page: 1, per_page: 50) do
      {:ok, %{rows: rows}} -> assign(socket, :events, rows)
      {:error, _reason} -> assign(socket, :events, [])
    end
  end

  defp load_runs(socket, page) do
    opts =
      []
      |> maybe_event_filter(socket.assigns.form["event_id"])
      |> Keyword.put(:page, page)
      |> Keyword.put(:actor, socket.assigns.current_user)

    case SyncDebug.list_runs(opts) do
      {:ok, %{rows: rows, page: page_info}} ->
        socket
        |> assign(:page, page_info)
        |> stream(:sync_runs, rows, reset: true)

      {:error, _reason} ->
        socket
        |> assign(:page, empty_page())
        |> stream(:sync_runs, [], reset: true)
        |> put_flash(:error, "Sync runs could not be loaded")
    end
  end

  defp maybe_event_filter(opts, event_id) when event_id in [nil, ""], do: opts
  defp maybe_event_filter(opts, event_id), do: Keyword.put(opts, :event_id, event_id)

  defp normalize_form(sync) do
    Map.merge(@empty_form, Map.take(sync, Map.keys(@empty_form)))
  end

  defp current_user(%{"current_user_id" => user_id}) when is_binary(user_id) do
    case Ash.get(User, user_id, domain: Accounts) do
      {:ok, %User{active: true} = user} -> user
      _other -> nil
    end
  end

  defp current_user(_session), do: nil

  defp current_user_id(%{"current_user_id" => user_id}) when is_binary(user_id), do: user_id
  defp current_user_id(%{current_user_id: user_id}) when is_binary(user_id), do: user_id
  defp current_user_id(_session), do: "unknown"

  defp empty_page, do: %{page: 1, per_page: 25, has_next?: false, has_previous?: false}

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
end
