defmodule EventSalesWeb.Live.Admin.WebhooksLive do
  @moduledoc """
  Admin webhook debug and replay UI.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Ingestion.{WebhookDebug, WebhookReplay}
  alias EventSalesWeb.Components.AdminShell
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter
  alias EventSalesWeb.Live.Admin.Pagination, as: AdminPagination
  alias EventSalesWeb.Live.Admin.Session, as: AdminSession

  @payload_display_max_bytes 20_000
  @empty_filters %{"status" => "", "topic" => "", "delivery_id" => "", "resource_id" => ""}

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Webhook Debug")
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:current_user_id, AdminSession.current_user_id(session))
      |> assign(:filters, @empty_filters)
      |> assign(:page, AdminPagination.empty_page())
      |> assign(:revealed_payload, nil)
      |> assign(:confirm_replay_id, nil)
      |> stream(:webhook_events, [])
      |> load_webhooks(1)

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:filters, normalize_filters(filters))
     |> assign(:revealed_payload, nil)
     |> assign(:confirm_replay_id, nil)
     |> load_webhooks(1)}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, load_webhooks(socket, socket.assigns.page.page + 1)}
  end

  def handle_event("previous_page", _params, socket) do
    {:noreply, load_webhooks(socket, max(socket.assigns.page.page - 1, 1))}
  end

  def handle_event("show_payload", %{"id" => webhook_event_id}, socket) do
    case WebhookDebug.get_payload(webhook_event_id, actor: socket.assigns.current_user) do
      {:ok, payload} ->
        {:noreply, assign(socket, :revealed_payload, %{id: webhook_event_id, payload: payload})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Payload could not be loaded")}
    end
  end

  def handle_event("hide_payload", _params, socket) do
    {:noreply, assign(socket, :revealed_payload, nil)}
  end

  def handle_event("confirm_replay", %{"id" => webhook_event_id}, socket) do
    {:noreply,
     socket
     |> assign(:confirm_replay_id, webhook_event_id)
     |> load_webhooks(socket.assigns.page.page)}
  end

  def handle_event("replay", %{"id" => webhook_event_id}, socket) do
    if socket.assigns.confirm_replay_id == webhook_event_id do
      replay_confirmed(socket, webhook_event_id)
    else
      {:noreply, assign(socket, :confirm_replay_id, webhook_event_id)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminShell.shell
      flash={@flash}
      current_path="/admin/webhooks"
      page_title="Webhook Debug"
      page_description="Internal webhook delivery log."
    >
      <form
        phx-change="filter"
        class="card mb-6 grid gap-3 border border-base-300 bg-base-100 p-4 shadow-sm md:grid-cols-4"
      >
        <label class="text-sm font-medium text-base-content/80">
          Status
          <select
            name="filters[status]"
            class="select select-bordered mt-1 w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
          >
            <option value="" selected={@filters["status"] == ""}>All</option>
            <option
              :for={status <- [:queued, :processing, :processed, :failed, :ignored, :buffered]}
              value={status}
              selected={@filters["status"] == to_string(status)}
            >
              {status}
            </option>
          </select>
        </label>
        <label class="text-sm font-medium text-base-content/80">
          Topic
          <input
            name="filters[topic]"
            value={@filters["topic"]}
            class="input input-bordered mt-1 w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
          />
        </label>
        <label class="text-sm font-medium text-base-content/80">
          Delivery
          <input
            name="filters[delivery_id]"
            value={@filters["delivery_id"]}
            class="input input-bordered mt-1 w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
          />
        </label>
        <label class="text-sm font-medium text-base-content/80">
          Resource
          <input
            name="filters[resource_id]"
            value={@filters["resource_id"]}
            class="input input-bordered mt-1 w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
          />
        </label>
      </form>

      <section class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table class="table table-zebra table-sm">
          <thead>
            <tr>
              <th class="px-3 py-2">Received</th>
              <th class="px-3 py-2">Topic</th>
              <th class="px-3 py-2">Resource</th>
              <th class="px-3 py-2">Delivery</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Attempts</th>
              <th class="px-3 py-2">Body</th>
              <th class="px-3 py-2">Actions</th>
            </tr>
          </thead>
          <tbody id="webhook-events" phx-update="stream" class="">
            <tr :for={{dom_id, webhook} <- @streams.webhook_events} id={dom_id}>
              <td class="whitespace-nowrap px-3 py-2 text-base-content/80">
                {format_datetime(webhook.received_at)}
              </td>
              <td class="px-3 py-2 text-base-content/80">{webhook.topic}</td>
              <td class="px-3 py-2 text-base-content/80">
                <div>{webhook.resource_type}</div>
                <div class="text-xs text-base-content/60">{webhook.resource_id}</div>
              </td>
              <td class="px-3 py-2 text-base-content/80">{webhook.delivery_id}</td>
              <td class="px-3 py-2 text-base-content/80">{webhook.status}</td>
              <td class="px-3 py-2 text-base-content/80">{webhook.processing_attempt_count}</td>
              <td class="px-3 py-2 text-base-content/80">{webhook.raw_body_size} bytes</td>
              <td class="px-3 py-2">
                <div class="flex flex-wrap gap-2">
                  <button
                    type="button"
                    phx-click="show_payload"
                    phx-value-id={webhook.id}
                    class="btn btn-outline btn-xs"
                  >
                    Show raw payload
                  </button>
                  <button
                    :if={webhook.status == :failed and @confirm_replay_id != webhook.id}
                    type="button"
                    phx-click="confirm_replay"
                    phx-value-id={webhook.id}
                    class="btn btn-outline btn-xs"
                  >
                    Replay
                  </button>
                  <button
                    :if={webhook.status == :failed and @confirm_replay_id == webhook.id}
                    type="button"
                    phx-click="replay"
                    phx-value-id={webhook.id}
                    class="btn btn-error btn-outline btn-xs"
                  >
                    Confirm replay
                  </button>
                </div>
                <div :if={webhook.error_message} class="mt-1 max-w-xs truncate text-xs text-red-700">
                  {webhook.error_message}
                </div>
                <div :if={webhook.ignore_reason} class="mt-1 text-xs text-base-content/60">
                  {webhook.ignore_reason}
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
          class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium text-base-content disabled:cursor-not-allowed disabled:bg-base-200 disabled:text-base-content/50"
        >
          Previous
        </button>
        <span class="text-sm text-base-content/70">Page {@page.page}</span>
        <button
          type="button"
          phx-click="next_page"
          disabled={!@page.has_next?}
          class="rounded border border-base-300 bg-base-100 px-3 py-2 text-sm font-medium text-base-content disabled:cursor-not-allowed disabled:bg-base-200 disabled:text-base-content/50"
        >
          Next
        </button>
      </div>

      <section :if={@revealed_payload} class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="mb-3 flex items-center justify-between">
            <h2 class="text-base font-semibold text-base-content">Raw Payload</h2>
            <button
              type="button"
              phx-click="hide_payload"
              class="btn btn-outline btn-xs"
            >
              Hide
            </button>
          </div>
          <pre class="max-h-96 overflow-auto whitespace-pre-wrap text-xs text-base-content">{format_payload(@revealed_payload.payload)}</pre>
        </div>
      </section>
    </AdminShell.shell>
    """
  end

  defp replay_confirmed(socket, webhook_event_id) do
    case ManualActionRateLimiter.allow?(socket.assigns.current_user_id, :webhook_replay) do
      :ok ->
        case WebhookReplay.replay_failed(webhook_event_id, actor: socket.assigns.current_user) do
          {:ok, _event} ->
            {:noreply,
             socket
             |> put_flash(:info, "Replay queued")
             |> assign(:confirm_replay_id, nil)
             |> load_webhooks(socket.assigns.page.page)}

          {:error, :enqueue_failed} ->
            {:noreply, put_flash(socket, :error, "Replay could not be enqueued")}

          {:error, :not_failed} ->
            {:noreply,
             socket
             |> put_flash(:error, "Only failed webhooks can be replayed")
             |> assign(:confirm_replay_id, nil)
             |> load_webhooks(socket.assigns.page.page)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Replay failed")}
        end

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Try again shortly")}
    end
  end

  defp load_webhooks(socket, page) do
    opts =
      socket.assigns.filters
      |> filters_to_opts()
      |> Keyword.put(:page, page)
      |> Keyword.put(:actor, socket.assigns.current_user)

    case WebhookDebug.list_events(opts) do
      {:ok, %{rows: rows, page: page_info}} ->
        socket
        |> assign(:page, page_info)
        |> stream(:webhook_events, rows, reset: true)

      {:error, _reason} ->
        socket
        |> assign(:page, AdminPagination.empty_page())
        |> stream(:webhook_events, [], reset: true)
        |> put_flash(:error, "Webhook events could not be loaded")
    end
  end

  defp filters_to_opts(filters) do
    filters
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp normalize_filters(filters) do
    Map.merge(@empty_filters, Map.take(filters, Map.keys(@empty_filters)))
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")

  defp format_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, encoded} -> cap_payload_display(encoded)
      {:error, _reason} -> payload |> inspect(pretty: true) |> cap_payload_display()
    end
  end

  defp cap_payload_display(encoded) when byte_size(encoded) <= @payload_display_max_bytes,
    do: encoded

  defp cap_payload_display(encoded) do
    encoded
    |> valid_binary_prefix(@payload_display_max_bytes)
    |> Kernel.<>("\n\n[truncated]")
  end

  defp valid_binary_prefix(_encoded, 0), do: ""

  defp valid_binary_prefix(encoded, bytes) do
    prefix = binary_part(encoded, 0, min(bytes, byte_size(encoded)))

    if String.valid?(prefix) do
      prefix
    else
      valid_binary_prefix(encoded, bytes - 1)
    end
  end
end
