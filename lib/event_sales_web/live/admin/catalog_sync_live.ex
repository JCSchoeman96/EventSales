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
    "manual_rows" => "",
    "product_id" => "",
    "variation_id" => "",
    "event_id" => "",
    "updated_since" => ""
  }

  @displayable_failure_codes ~w(
    discovery_source_not_configured
    invalid_manual_rows
    missing_manual_rows
    catalog_feed_misconfigured
    catalog_feed_unauthorized
    catalog_feed_forbidden
    catalog_feed_timeout
    catalog_feed_pagination_limit
    invalid_catalog_feed_response
    catalog_feed_rate_limited
    catalog_feed_server_error
    catalog_feed_transport_error
    catalog_sync_discovery_failed
    enqueue_failed
    stale_dry_run_hash
    missing_plan_snapshot
    blocking_findings
    run_not_ready
    not_found
    catalog_sync_apply_failed
    catalog_sync_failed
  )

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Catalog Sync")
      |> assign(:current_user, AdminSession.current_user(session))
      |> assign(:form, @empty_form)
      |> assign(:form_state, validate_form(@empty_form))
      |> assign(:queue_notice, nil)
      |> assign(:source_systems, [])
      |> assign(:runs, [])
      |> assign(:previews, %{})
      |> load_source_systems()
      |> load_runs()

    {:ok, socket}
  end

  @impl true
  def handle_event("update_form", %{"catalog_sync" => form}, socket) do
    form = normalize_form(form)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:form_state, validate_form(form))
     |> assign(:queue_notice, nil)}
  end

  def handle_event("queue_dry_run", %{"catalog_sync" => form}, socket) do
    form = normalize_form(form)
    form_state = validate_form(form)

    with :ok <- validate_queue_ready(form_state),
         {:ok, scope} <- build_scope(form),
         {:ok, %{run: _run}} <-
           TickeraCatalogSync.queue_dry_run(
             %{source_system_id: form["source_system_id"], scope: scope},
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Catalog dry-run queued")
       |> assign(:form, form)
       |> assign(:form_state, form_state)
       |> assign(:queue_notice, {:success, "Catalog dry-run queued"})
       |> load_runs()}
    else
      {:error, :source_required} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:form_state, form_state)
         |> assign(:queue_notice, {:error, "Select a source system before queueing"})
         |> put_flash(:error, "Select a source system before queueing")}

      {:error, :invalid_manual_rows} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:form_state, form_state)
         |> assign(:queue_notice, {:error, "Manual rows must be valid JSON"})
         |> put_flash(:error, "Manual rows must be valid JSON")}

      {:error, :invalid_feed_scope} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:form_state, form_state)
         |> assign(:queue_notice, {:error, "WordPress feed scope is invalid"})
         |> put_flash(:error, "WordPress feed scope is invalid")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:queue_notice, {:error, "You are not allowed to run catalog sync"})
         |> put_flash(:error, "You are not allowed to run catalog sync")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:queue_notice, {:error, "Catalog dry-run could not be queued"})
         |> put_flash(:error, "Catalog dry-run could not be queued")}
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
          <h2 class="mb-4 text-base font-semibold text-base-content">
            Run Tickera catalog dry-run
          </h2>
          <form
            id="catalog-sync-form"
            phx-change="update_form"
            phx-submit="queue_dry_run"
            class="grid gap-4"
          >
            <div
              :if={@queue_notice}
              class={[
                "alert py-3 text-sm",
                queue_notice_class(@queue_notice)
              ]}
            >
              {elem(@queue_notice, 1)}
            </div>

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Source system</span>
                <span :if={!@form_state.source_selected?} class="label-text-alt text-warning">
                  Needed
                </span>
              </span>
              <select
                name="catalog_sync[source_system_id]"
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
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

            <label class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Scope</span>
              </span>
              <select
                name="catalog_sync[scope_kind]"
                class="select select-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
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
                <option
                  value="wordpress_feed_full"
                  selected={@form["scope_kind"] == "wordpress_feed_full"}
                >
                  WordPress feed full catalog
                </option>
                <option
                  value="wordpress_feed_product"
                  selected={@form["scope_kind"] == "wordpress_feed_product"}
                >
                  WordPress feed Woo product ID
                </option>
                <option
                  value="wordpress_feed_variation"
                  selected={@form["scope_kind"] == "wordpress_feed_variation"}
                >
                  WordPress feed Woo variation ID
                </option>
                <option
                  value="wordpress_feed_event"
                  selected={@form["scope_kind"] == "wordpress_feed_event"}
                >
                  WordPress feed Tickera event ID
                </option>
                <option
                  value="wordpress_feed_updated_since"
                  selected={@form["scope_kind"] == "wordpress_feed_updated_since"}
                >
                  WordPress feed updated since
                </option>
              </select>
            </label>

            <label :if={@form["scope_kind"] == "wordpress_feed_product"} class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Woo product ID</span>
              </span>
              <input
                type="number"
                min="1"
                name="catalog_sync[product_id]"
                value={@form["product_id"]}
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
              <span :if={@form_state.scope_error} class="label pt-1">
                <span class="label-text-alt text-error">{@form_state.scope_error}</span>
              </span>
            </label>

            <label
              :if={@form["scope_kind"] == "wordpress_feed_variation"}
              class="form-control w-full"
            >
              <span class="label">
                <span class="label-text font-medium text-base-content">Woo variation ID</span>
              </span>
              <input
                type="number"
                min="1"
                name="catalog_sync[variation_id]"
                value={@form["variation_id"]}
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
              <span :if={@form_state.scope_error} class="label pt-1">
                <span class="label-text-alt text-error">{@form_state.scope_error}</span>
              </span>
            </label>

            <label :if={@form["scope_kind"] == "wordpress_feed_event"} class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">Tickera event ID</span>
              </span>
              <input
                type="number"
                min="1"
                name="catalog_sync[event_id]"
                value={@form["event_id"]}
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
              <span :if={@form_state.scope_error} class="label pt-1">
                <span class="label-text-alt text-error">{@form_state.scope_error}</span>
              </span>
            </label>

            <label
              :if={@form["scope_kind"] == "wordpress_feed_updated_since"}
              class="form-control w-full"
            >
              <span class="label">
                <span class="label-text font-medium text-base-content">Updated since</span>
              </span>
              <input
                type="text"
                name="catalog_sync[updated_since]"
                value={@form["updated_since"]}
                placeholder="2026-07-05T10:00:00Z"
                class="input input-bordered w-full bg-base-200 text-base-content focus:outline-none focus:ring-2 focus:ring-primary/60"
              />
              <span :if={@form_state.scope_error} class="label pt-1">
                <span class="label-text-alt text-error">{@form_state.scope_error}</span>
              </span>
            </label>

            <label :if={!feed_scope?(@form["scope_kind"])} class="form-control w-full">
              <span class="label">
                <span class="label-text font-medium text-base-content">
                  Sanitized manual export rows JSON
                </span>
                <span class={json_status_class(@form_state)}>
                  {json_status_text(@form_state)}
                </span>
              </span>
              <textarea
                name="catalog_sync[manual_rows]"
                rows="8"
                spellcheck="false"
                class="textarea textarea-bordered min-h-48 w-full bg-base-200 font-mono text-xs leading-5 text-base-content placeholder:text-base-content/50 focus:outline-none focus:ring-2 focus:ring-primary/60"
                placeholder="Paste sanitized manual export JSON"
              >{@form["manual_rows"]}</textarea>
              <span :if={@form_state.manual_json_error} class="label pt-1">
                <span class="label-text-alt text-error">{@form_state.manual_json_error}</span>
              </span>
            </label>

            <div>
              <button
                type="submit"
                disabled={!@form_state.queue_enabled?}
                phx-disable-with="Queueing dry-run..."
                class="btn btn-primary cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Queue dry-run
              </button>
            </div>
          </form>
        </div>
      </section>

      <section class="overflow-x-auto rounded-lg border border-base-300 bg-base-100">
        <table class="table table-zebra min-w-full text-sm">
          <thead class="bg-base-200 text-left text-xs font-semibold uppercase text-base-content/70">
            <tr>
              <th class="px-3 py-2">Queued</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Failure reason</th>
              <th class="px-3 py-2">Hash</th>
              <th class="px-3 py-2">Summary</th>
              <th class="px-3 py-2">Action</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs}>
              <td class="px-3 py-2 text-base-content/80">{format_datetime(run.inserted_at)}</td>
              <td class="px-3 py-2 text-base-content/80">{run.status}</td>
              <td class="px-3 py-2 font-mono text-xs text-base-content/80">
                {failure_reason_text(run)}
              </td>
              <td class="px-3 py-2 font-mono text-xs text-base-content/80">
                {run.dry_run_hash || "-"}
              </td>
              <td class="px-3 py-2 text-xs text-base-content/80">{summary_text(run.summary)}</td>
              <td class="px-3 py-2">
                <button
                  type="button"
                  phx-click="queue_apply"
                  phx-value-run_id={run.id}
                  phx-value-dry_run_hash={run.dry_run_hash}
                  disabled={!apply_enabled?(run, preview(@previews, run.id))}
                  class="btn btn-primary btn-xs cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2 focus-visible:ring-offset-base-100 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Apply
                </button>
              </td>
            </tr>
            <tr :for={run <- @runs}>
              <td class="px-3 py-4" colspan="6">
                <div class="space-y-4">
                  <div :if={findings(preview(@previews, run.id)) != []}>
                    <h3 class="mb-2 text-xs font-semibold uppercase text-base-content/70">
                      Findings
                    </h3>
                    <div class="overflow-x-auto rounded border border-base-300 bg-base-100">
                      <table class="table table-zebra min-w-full text-xs">
                        <thead class="bg-base-200 text-left text-[0.65rem] font-semibold uppercase text-base-content/70">
                          <tr>
                            <th class="px-2 py-2">Severity</th>
                            <th class="px-2 py-2">Code</th>
                            <th class="px-2 py-2">Message</th>
                            <th class="px-2 py-2">Tickera event ID</th>
                            <th class="px-2 py-2">Woo product ID</th>
                            <th class="px-2 py-2">Woo variation ID</th>
                            <th class="px-2 py-2">Reason</th>
                            <th class="px-2 py-2">TicketType name</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr
                            :for={finding <- finding_detail_rows(preview(@previews, run.id))}
                            class={[
                              "text-base-content/80",
                              blocking_finding?(finding) && "border-l-4 border-error"
                            ]}
                          >
                            <td class={[
                              "px-2 py-2 font-semibold",
                              blocking_finding?(finding) && "text-error"
                            ]}>
                              {finding.severity}
                            </td>
                            <td class="px-2 py-2 font-mono">{finding.code}</td>
                            <td class="px-2 py-2">{finding.message}</td>
                            <td class="px-2 py-2 font-mono">{finding.tickera_event_id}</td>
                            <td class="px-2 py-2 font-mono">{finding.woo_product_id}</td>
                            <td class="px-2 py-2 font-mono">{finding.woo_variation_id}</td>
                            <td class="px-2 py-2 font-mono">{finding.reason}</td>
                            <td class="px-2 py-2 font-mono">{finding.ticket_type_name}</td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                    <div class="mt-3">
                      <h4 class="mb-2 text-xs font-semibold uppercase text-base-content/70">
                        Finding review report
                      </h4>
                      <pre class="overflow-x-auto rounded bg-base-200 p-3 text-xs leading-5 text-base-content/80">{finding_report(preview(@previews, run.id))}</pre>
                    </div>
                  </div>

                  <div :if={preview_event_groups(preview(@previews, run.id)) != []}>
                    <h3 class="mb-2 text-xs font-semibold uppercase text-base-content/70">
                      Proposed Catalog Changes
                    </h3>
                    <div class="space-y-3">
                      <div
                        :for={group <- preview_event_groups(preview(@previews, run.id))}
                        class="rounded border border-base-300 bg-base-100 px-3 py-2"
                      >
                        <div class="text-sm font-medium text-base-content">{group.event_label}</div>
                        <div class="mt-2 grid gap-2 text-xs text-base-content/80 md:grid-cols-3">
                          <div>
                            <div class="font-semibold uppercase text-base-content/60">Event</div>
                            <div :for={change <- group.event_changes}>
                              {value(change, "action")} Tickera event {value(
                                change,
                                "external_event_id"
                              ) ||
                                value(change, "event_id")}
                            </div>
                          </div>
                          <div>
                            <div class="font-semibold uppercase text-base-content/60">
                              Ticket Types
                            </div>
                            <div :for={change <- group.ticket_type_changes}>
                              {value(change, "action")} {value(change, "name") ||
                                value(change, "external_ticket_type_id")}
                            </div>
                          </div>
                          <div>
                            <div class="font-semibold uppercase text-base-content/60">Mappings</div>
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
              <td class="px-3 py-6 text-center text-base-content/60" colspan="5">
                No catalog sync runs yet.
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </AdminShell.shell>
    """
  end

  defp build_scope(%{"scope_kind" => "wordpress_feed_full"}) do
    {:ok, %{"kind" => "wordpress_feed", "mode" => "full"}}
  end

  defp build_scope(%{"scope_kind" => "wordpress_feed_product", "product_id" => product_id}) do
    with {:ok, id} <- positive_id(product_id) do
      {:ok, %{"kind" => "wordpress_feed", "product_id" => id}}
    end
  end

  defp build_scope(%{"scope_kind" => "wordpress_feed_variation", "variation_id" => variation_id}) do
    with {:ok, id} <- positive_id(variation_id) do
      {:ok, %{"kind" => "wordpress_feed", "variation_id" => id}}
    end
  end

  defp build_scope(%{"scope_kind" => "wordpress_feed_event", "event_id" => event_id}) do
    with {:ok, id} <- positive_id(event_id) do
      {:ok, %{"kind" => "wordpress_feed", "event_id" => id}}
    end
  end

  defp build_scope(%{
         "scope_kind" => "wordpress_feed_updated_since",
         "updated_since" => updated_since
       }) do
    with :ok <- validate_rfc3339(updated_since) do
      {:ok, %{"kind" => "wordpress_feed", "updated_since" => String.trim(updated_since)}}
    end
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

  defp validate_form(form) do
    source_selected? = form["source_system_id"] |> to_string() |> String.trim() != ""
    scope_error = scope_error(form)

    {manual_json_present?, manual_json_valid?, manual_json_error} =
      validate_manual_json(form["manual_rows"])

    feed_scope? = feed_scope?(form["scope_kind"])

    %{
      source_selected?: source_selected?,
      manual_json_present?: manual_json_present?,
      manual_json_valid?: manual_json_valid?,
      manual_json_error: manual_json_error,
      scope_error: scope_error,
      feed_scope?: feed_scope?,
      queue_enabled?:
        source_selected? and is_nil(scope_error) and
          (feed_scope? or (manual_json_present? and manual_json_valid?))
    }
  end

  defp validate_manual_json(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {false, true, nil}
    else
      case Jason.decode(value) do
        {:ok, %{}} -> {true, true, nil}
        {:ok, _other} -> {true, false, "Manual rows JSON must be an object"}
        {:error, _reason} -> {true, false, "Invalid JSON"}
      end
    end
  end

  defp validate_manual_json(_value), do: {false, true, nil}

  defp validate_queue_ready(%{source_selected?: false}), do: {:error, :source_required}

  defp validate_queue_ready(%{scope_error: error}) when is_binary(error),
    do: {:error, :invalid_feed_scope}

  defp validate_queue_ready(%{feed_scope?: true}), do: :ok
  defp validate_queue_ready(%{manual_json_present?: false}), do: {:error, :invalid_manual_rows}
  defp validate_queue_ready(%{manual_json_valid?: false}), do: {:error, :invalid_manual_rows}
  defp validate_queue_ready(_form_state), do: :ok

  defp scope_error(%{"scope_kind" => "wordpress_feed_product", "product_id" => product_id}) do
    case positive_id(product_id) do
      {:ok, _id} -> nil
      {:error, _reason} -> "Enter a positive Woo product ID"
    end
  end

  defp scope_error(%{"scope_kind" => "wordpress_feed_variation", "variation_id" => variation_id}) do
    case positive_id(variation_id) do
      {:ok, _id} -> nil
      {:error, _reason} -> "Enter a positive Woo variation ID"
    end
  end

  defp scope_error(%{"scope_kind" => "wordpress_feed_event", "event_id" => event_id}) do
    case positive_id(event_id) do
      {:ok, _id} -> nil
      {:error, _reason} -> "Enter a positive Tickera event ID"
    end
  end

  defp scope_error(%{
         "scope_kind" => "wordpress_feed_updated_since",
         "updated_since" => updated_since
       }) do
    case validate_rfc3339(updated_since) do
      :ok -> nil
      {:error, _reason} -> "Enter updated_since as RFC3339"
    end
  end

  defp scope_error(_form), do: nil

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid}
    end
  end

  defp positive_id(_value), do: {:error, :invalid}

  defp validate_rfc3339(value) when is_binary(value) do
    value = String.trim(value)

    with true <-
           Regex.match?(
             ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/,
             value
           ),
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(value) do
      :ok
    else
      _error -> {:error, :invalid}
    end
  end

  defp validate_rfc3339(_value), do: {:error, :invalid}

  defp feed_scope?("wordpress_feed_full"), do: true
  defp feed_scope?("wordpress_feed_product"), do: true
  defp feed_scope?("wordpress_feed_variation"), do: true
  defp feed_scope?("wordpress_feed_event"), do: true
  defp feed_scope?("wordpress_feed_updated_since"), do: true
  defp feed_scope?(_scope_kind), do: false

  defp json_status_text(%{manual_json_present?: false}), do: "Paste sanitized manual export JSON"
  defp json_status_text(%{manual_json_valid?: true}), do: "Valid JSON"
  defp json_status_text(_form_state), do: "Invalid JSON"

  defp json_status_class(%{manual_json_present?: false}),
    do: "label-text-alt text-base-content/60"

  defp json_status_class(%{manual_json_valid?: true}), do: "label-text-alt text-success"
  defp json_status_class(_form_state), do: "label-text-alt text-error"

  defp queue_notice_class({:success, _message}), do: "alert-success"
  defp queue_notice_class({:error, _message}), do: "alert-error"

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
      preview_ready?(run, preview) and
      not blocking_findings?(preview)
  end

  defp preview_ready?(run, preview) when is_map(preview) do
    value(preview, "dry_run_hash") == run.dry_run_hash
  end

  defp preview_ready?(_run, _preview), do: false

  defp blocking_findings?(preview), do: Enum.any?(findings(preview), &blocking_finding?/1)

  defp blocking_finding?(finding), do: value(finding, "severity") in [:blocking, "blocking"]

  defp findings(preview), do: list(preview, "findings")

  defp finding_detail_rows(preview), do: Enum.map(findings(preview), &finding_detail_row/1)

  defp finding_detail_row(finding) do
    %{
      severity: display_value(value(finding, "severity")),
      code: display_value(value(finding, "code")),
      message: display_value(value(finding, "message")),
      tickera_event_id: display_value(value(finding, "tickera_event_id")),
      woo_product_id: display_value(value(finding, "woo_product_id")),
      woo_variation_id: display_value(value(finding, "woo_variation_id")),
      reason: display_value(finding_metadata_value(finding, "reason")),
      ticket_type_name: display_value(finding_metadata_value(finding, "ticket_type_name"))
    }
  end

  defp finding_metadata_value(finding, key) when key in ["reason", "ticket_type_name"] do
    case value(finding, "metadata") do
      metadata when is_map(metadata) -> value(metadata, key)
      _metadata -> nil
    end
  end

  defp finding_metadata_value(_finding, _key), do: nil

  defp finding_report(preview) do
    rows =
      preview
      |> finding_detail_rows()
      |> Enum.map_join("\n", fn finding ->
        [
          finding.severity,
          finding.code,
          finding.tickera_event_id,
          finding.woo_product_id,
          finding.woo_variation_id,
          finding.reason,
          finding.ticket_type_name
        ]
        |> Enum.join(" | ")
      end)

    [
      "severity | code | tickera_event_id | woo_product_id | woo_variation_id | reason | ticket_type_name",
      rows
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

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

  defp display_value(nil), do: "-"
  defp display_value(""), do: "-"

  defp display_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "-", else: value
  end

  defp display_value(value) when is_atom(value), do: Atom.to_string(value)
  defp display_value(value), do: to_string(value)

  defp summary_text(summary) when is_map(summary) and map_size(summary) > 0 do
    Enum.map_join(summary, ", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp summary_text(_summary), do: "-"

  defp failure_reason_text(%{status: :failed, last_error: last_error})
       when is_binary(last_error) do
    if last_error in @displayable_failure_codes do
      last_error
    else
      "catalog_sync_failed"
    end
  end

  defp failure_reason_text(_run), do: "-"

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
