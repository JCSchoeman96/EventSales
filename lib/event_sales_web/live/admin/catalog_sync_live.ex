defmodule EventSalesWeb.Live.Admin.CatalogSyncLive do
  @moduledoc """
  Admin Tickera catalog dry-run/apply UI.
  """

  use EventSalesWeb, :live_view

  alias EventSales.Catalog.MappingConflictResolver
  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.CatalogChangePendingTarget
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Sales.OrderAttributionCorrection
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
    catalog_sync_claim_failed
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
      |> assign(:active_run, nil)
      |> assign(:source_systems, [])
      |> assign(:runs, [])
      |> assign(:catalog_change_targets, load_catalog_change_targets())
      |> assign(:selected_run_id, nil)
      |> assign(:selected_run, nil)
      |> assign(:subscribed_run_ids, MapSet.new())
      |> assign(:previews, %{})
      |> assign(:mapping_conflicts, %{})
      |> assign(:mapping_conflict_errors, %{})
      |> assign(:revoke_modal_run_id, nil)
      |> assign(:revoke_form, %{
        "cancellation_reason_code" => "",
        "cancellation_reason_details" => ""
      })
      |> assign(:order_correction_preview, nil)
      |> assign(:order_correction_error, nil)
      |> load_source_systems()
      |> load_order_correction_preview()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_run_id = params["run_id"]

    socket =
      if requested_run_id && requested_run_id == socket.assigns.selected_run_id &&
           socket.assigns.selected_run do
        socket
      else
        load_runs(socket, requested_run_id)
      end

    if (connected?(socket) and socket.assigns.selected_run_id) &&
         requested_run_id != socket.assigns.selected_run_id do
      {:noreply, push_patch(socket, to: selected_run_path(socket.assigns.selected_run_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_form", %{"catalog_sync" => form}, socket) do
    form = normalize_form(form)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:form_state, validate_form(form))
     |> assign(:queue_notice, nil)
     |> load_active_run(form)
     |> load_order_correction_preview()}
  end

  def handle_event("queue_dry_run", %{"catalog_sync" => form}, socket) do
    form = normalize_form(form)
    form_state = validate_form(form)

    with :ok <- validate_queue_ready(form_state),
         {:ok, scope} <- build_scope(form),
         {:ok, %{run: run}} <-
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
       |> push_patch(to: selected_run_path(run.id))}
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

      {:error, :catalog_sync_already_active} ->
        {:noreply,
         socket
         |> assign(:queue_notice, {:error, active_run_message()})
         |> put_flash(:error, active_run_message())}

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
    with :ok <- validate_selected_apply(socket, run_id, dry_run_hash),
         {:ok, _queued} <-
           TickeraCatalogSync.queue_apply(run_id, dry_run_hash,
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Catalog apply queued")
       |> load_runs(run_id)}
    else
      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to apply catalog sync")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Catalog apply could not be queued")}
    end
  end

  def handle_event("open_revoke_dry_run", %{"run_id" => run_id}, socket) do
    case socket.assigns.selected_run do
      %{id: ^run_id, status: :dry_run_ready} ->
        {:noreply,
         socket
         |> assign(:revoke_modal_run_id, run_id)
         |> assign(:revoke_form, %{
           "cancellation_reason_code" => "",
           "cancellation_reason_details" => ""
         })}

      _other ->
        {:noreply, put_flash(socket, :error, "This catalog dry-run is no longer ready")}
    end
  end

  def handle_event("close_revoke_dry_run", _params, socket) do
    {:noreply, close_revoke_modal(socket)}
  end

  def handle_event("validate_revoke_dry_run", params, socket) do
    {:noreply, assign(socket, :revoke_form, revoke_form(params))}
  end

  def handle_event("revoke_dry_run", params, socket) do
    form = revoke_form(params)

    with %{id: run_id, status: :dry_run_ready} <- socket.assigns.selected_run,
         ^run_id <- socket.assigns.revoke_modal_run_id,
         {:ok, _revoked} <-
           TickeraCatalogSync.revoke_ready_dry_run(run_id, form,
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> close_revoke_modal()
       |> put_flash(:info, "Catalog dry-run revoked")
       |> load_runs(run_id)}
    else
      {:error, :already_cancelled} ->
        {:noreply,
         socket
         |> close_revoke_modal()
         |> put_flash(:error, "This catalog dry-run was already revoked")
         |> reload_selected_run()}

      {:error, :run_already_claimed} ->
        {:noreply,
         socket
         |> close_revoke_modal()
         |> put_flash(:error, "This catalog dry-run was already claimed for Apply")
         |> reload_selected_run()}

      {:error, :reason_details_required} ->
        {:noreply,
         socket
         |> assign(:revoke_form, form)
         |> put_flash(:error, "Enter details when selecting Other reason")}

      {:error, :reason_details_too_long} ->
        {:noreply,
         socket
         |> assign(:revoke_form, form)
         |> put_flash(:error, "Revocation details must be 500 characters or fewer")}

      {:error, :invalid_reason_code} ->
        {:noreply,
         socket
         |> assign(:revoke_form, form)
         |> put_flash(:error, "Select a revocation reason")}

      _other ->
        {:noreply,
         socket
         |> assign(:revoke_form, form)
         |> put_flash(:error, "Catalog dry-run could not be revoked")}
    end
  end

  def handle_event("deactivate_stale_mapping", params, socket) do
    case MappingConflictResolver.deactivate_stale_mapping(
           value(params, "run_id"),
           value(params, "dry_run_hash"),
           value(params, "woo_product_id"),
           value(params, "woo_variation_id"),
           actor: socket.assigns.current_user
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stale mapping deactivated. Rerun full-feed dry-run.")
         |> reload_selected_run()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mapping conflict resolution failed: #{reason}")}
    end
  end

  def handle_event("cutover_stale_mapping", params, socket) do
    case MappingConflictResolver.cutover_stale_mapping(
           value(params, "run_id"),
           value(params, "dry_run_hash"),
           value(params, "woo_product_id"),
           value(params, "woo_variation_id"),
           value(params, "stale_mapped_event_external_id"),
           value(params, "feed_tickera_event_id"),
           value(params, "confirmation") || "",
           actor: socket.assigns.current_user
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Stale mapping cut over. Existing order items were not changed. Rerun full-feed dry-run."
         )
         |> reload_selected_run()
         |> load_order_correction_preview()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mapping cutover failed: #{reason}")}
    end
  end

  def handle_event("correct_order_attribution", params, socket) do
    source_system_id = correction_source_system_id(socket)

    case OrderAttributionCorrection.correct_confirmed_order_113834(
           source_system_id,
           value(params, "confirmation") || "",
           actor: socket.assigns.current_user
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Order attribution corrected for Woo order 113834.")
         |> load_order_correction_preview()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Order attribution correction failed: #{reason}")
         |> assign(:order_correction_error, Atom.to_string(reason))}
    end
  end

  @impl true
  def handle_info({event, %{run_id: _run_id}}, socket)
      when event in [
             :catalog_sync_started,
             :catalog_sync_retry_scheduled,
             :catalog_sync_preview_ready,
             :catalog_sync_failed,
             :catalog_sync_applied,
             :catalog_sync_cancelled
           ] do
    socket = load_runs(socket, socket.assigns.selected_run_id)
    {:noreply, load_active_run(socket, socket.assigns.form)}
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
          <h2 class="card-title text-base">WordPress catalog changes</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Target</th>
                  <th>State</th>
                  <th>Generation</th>
                  <th>Reason</th>
                  <th>Run</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={target <- @catalog_change_targets}>
                  <td>{target.target_type}:{target.target_id}</td>
                  <td>{target.state}</td>
                  <td>{target.dispatched_generation}/{target.generation}</td>
                  <td>
                    {target.latest_reason}
                    <span :if={target.latest_reason == :deleted} class="badge badge-warning ml-2">
                      deletion_not_reconciled
                    </span>
                  </td>
                  <td>{target.catalog_sync_run_id || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
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

            <p :if={@active_run} class="text-sm text-warning">{active_run_message()}</p>

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
              <th class="px-3 py-2">Created at</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Failure reason</th>
              <th class="px-3 py-2">Hash</th>
              <th class="px-3 py-2">Summary</th>
              <th class="px-3 py-2">View</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs}>
              <td class="px-3 py-2 text-base-content/80">{format_datetime(run.inserted_at)}</td>
              <td class="px-3 py-2 text-base-content/80">
                <span class="badge badge-outline gap-1">
                  <span :if={status_spinner?(run.status)} class="loading loading-spinner loading-xs">
                  </span>
                  <span :if={status_clock?(run.status)}>◷</span>
                  {status_label(run.status)}
                </span>
              </td>
              <td class="px-3 py-2 font-mono text-xs text-base-content/80">
                {failure_reason_text(run)}
              </td>
              <td class="px-3 py-2 font-mono text-xs text-base-content/80">
                {run.dry_run_hash || "-"}
              </td>
              <td class="px-3 py-2 text-xs text-base-content/80">{summary_text(run.summary)}</td>
              <td class="px-3 py-2">
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    :if={run.id != @selected_run_id}
                    patch={selected_run_path(run.id)}
                    class="btn btn-ghost btn-xs"
                  >
                    View
                  </.link>
                  <span :if={run.id == @selected_run_id} class="badge badge-outline badge-sm">
                    Currently viewing
                  </span>
                </div>
              </td>
            </tr>
            <tr :for={run <- selected_run_list(@selected_run)}>
              <td class="px-3 py-4" colspan="6">
                <div class="space-y-4">
                  <section class="rounded border border-base-300 bg-base-200/40 p-3">
                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <div>
                        <h3 class="text-xs font-semibold uppercase text-base-content/70">
                          Selected run actions
                        </h3>
                        <p class="mt-1 font-mono text-xs text-base-content/70">{run.id}</p>
                      </div>
                      <div :if={run.status == :dry_run_ready} class="flex flex-wrap gap-2">
                        <button
                          id={"catalog-sync-apply-#{run.id}"}
                          type="button"
                          phx-click="queue_apply"
                          phx-value-run_id={run.id}
                          phx-value-dry_run_hash={run.dry_run_hash}
                          disabled={!apply_enabled?(run, preview(@previews, run.id))}
                          class="btn btn-primary btn-sm cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
                        >
                          Apply
                        </button>
                        <button
                          id={"catalog-sync-revoke-#{run.id}"}
                          type="button"
                          phx-click="open_revoke_dry_run"
                          phx-value-run_id={run.id}
                          class="btn btn-error btn-outline btn-sm"
                        >
                          Revoke dry-run
                        </button>
                      </div>
                    </div>

                    <div
                      :if={run.status == :cancelled}
                      class="alert alert-warning mt-3 items-start text-sm"
                    >
                      <div>
                        <div class="font-semibold">
                          Revoked by {cancelled_by_name(run)} at {format_datetime(run.cancelled_at)}
                        </div>
                        <div>Reason: {cancellation_reason_label(run.cancellation_reason_code)}</div>
                        <div :if={run.cancellation_reason_details}>
                          Details: {run.cancellation_reason_details}
                        </div>
                      </div>
                    </div>
                  </section>

                  <div
                    :if={@revoke_modal_run_id == run.id and run.status == :dry_run_ready}
                    id={"catalog-sync-revoke-modal-#{run.id}"}
                    class="modal modal-open"
                    role="dialog"
                    aria-modal="true"
                    aria-labelledby={"catalog-sync-revoke-title-#{run.id}"}
                  >
                    <div class="modal-box max-w-2xl">
                      <h3
                        id={"catalog-sync-revoke-title-#{run.id}"}
                        class="text-lg font-semibold"
                      >
                        Revoke this dry-run?
                      </h3>
                      <p class="mt-2 text-sm text-base-content/80">
                        Its snapshot will remain available for audit, but it can never be applied.
                      </p>

                      <dl class="mt-4 grid gap-2 text-sm md:grid-cols-2">
                        <div>
                          <dt class="font-semibold">Run ID</dt>
                          <dd class="font-mono">{run.id}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Source</dt>
                          <dd>{source_name(@source_systems, run.source_system_id)}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Scope</dt>
                          <dd>{scope_label(run.scope)}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Dry-run hash</dt>
                          <dd class="break-all font-mono text-xs">{run.dry_run_hash}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Event changes</dt>
                          <dd>{change_count(preview(@previews, run.id), "event_changes")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">TicketType changes</dt>
                          <dd>{change_count(preview(@previews, run.id), "ticket_type_changes")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Mapping changes</dt>
                          <dd>
                            {change_count(preview(@previews, run.id), "product_mapping_changes")}
                          </dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Warning findings</dt>
                          <dd>{finding_count(preview(@previews, run.id), "warning")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Blocking findings</dt>
                          <dd>{finding_count(preview(@previews, run.id), "blocking")}</dd>
                        </div>
                      </dl>

                      <form
                        id="catalog-sync-revoke-form"
                        phx-change="validate_revoke_dry_run"
                        phx-submit="revoke_dry_run"
                        class="mt-5 space-y-4"
                      >
                        <label class="form-control w-full">
                          <span class="label-text font-medium">Reason</span>
                          <select
                            name="cancellation_reason_code"
                            class="select select-bordered w-full"
                            required
                          >
                            <option value="" selected={@revoke_form["cancellation_reason_code"] == ""}>
                              Select a reason
                            </option>
                            <option
                              :for={{code, label} <- cancellation_reason_options()}
                              value={code}
                              selected={@revoke_form["cancellation_reason_code"] == code}
                            >
                              {label}
                            </option>
                          </select>
                        </label>
                        <label class="form-control w-full">
                          <span class="label-text font-medium">
                            {if @revoke_form["cancellation_reason_code"] == "other",
                              do: "Details — required",
                              else: "Additional details — optional"}
                          </span>
                          <textarea
                            name="cancellation_reason_details"
                            maxlength="500"
                            required={@revoke_form["cancellation_reason_code"] == "other"}
                            class="textarea textarea-bordered min-h-24 w-full"
                          >{@revoke_form["cancellation_reason_details"]}</textarea>
                        </label>
                        <div class="modal-action">
                          <button type="button" phx-click="close_revoke_dry_run" class="btn btn-ghost">
                            Keep dry-run
                          </button>
                          <button type="submit" class="btn btn-error">Confirm revocation</button>
                        </div>
                      </form>
                    </div>
                    <button
                      type="button"
                      phx-click="close_revoke_dry_run"
                      class="modal-backdrop"
                      aria-label="Close revocation dialog"
                    >
                      close
                    </button>
                  </div>

                  <section class="rounded border border-base-300 bg-base-100 p-4">
                    <h3 class="text-sm font-semibold">Historical impact forecast</h3>
                    <div
                      :if={is_nil(historical_impact(preview(@previews, run.id)))}
                      class="mt-2 text-sm text-base-content/70"
                    >
                      Forecast unavailable for this earlier run
                    </div>
                    <div
                      :if={impact = historical_impact(preview(@previews, run.id))}
                      class="mt-3 space-y-3 text-sm"
                    >
                      <div class="alert alert-info text-sm">{value(impact, "forecast_notice")}</div>
                      <dl class="grid gap-2 md:grid-cols-3">
                        <div>
                          <dt class="font-semibold">Observed</dt>
                          <dd>{value(impact, "order_state_observed_at") || "-"}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Affected pending lines</dt>
                          <dd>{impact_total(impact, "affected_pending_lines")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Affected quantity</dt>
                          <dd>{impact_total(impact, "affected_quantity")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Eligible now</dt>
                          <dd>{impact_total(impact, "eligible_lines")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Deferred on-hold</dt>
                          <dd>{impact_total(impact, "deferred_lines")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Conflicting</dt>
                          <dd>{impact_total(impact, "conflicting_lines")}</dd>
                        </div>
                        <div>
                          <dt class="font-semibold">Already mapped</dt>
                          <dd>{impact_total(impact, "already_mapped_lines")}</dd>
                        </div>
                      </dl>
                      <div class="overflow-x-auto">
                        <h4 class="font-semibold">Touched product/variation pairs</h4>
                        <table class="table table-zebra mt-1 text-xs">
                          <thead>
                            <tr>
                              <th>Pair</th>
                              <th>Resolution</th>
                              <th>Destination</th>
                              <th>Pending qty</th>
                              <th>Eligible</th>
                              <th>Deferred</th>
                              <th>Conflict</th>
                              <th>Mapped</th>
                              <th>Source identities</th>
                            </tr>
                          </thead>
                          <tbody>
                            <tr :for={pair <- impact_entries(impact, "by_product_variation")}>
                              <td>
                                {value(pair, "woo_product_id")} / {value(pair, "woo_variation_id") ||
                                  "-"}
                              </td>
                              <td>{value(pair, "resolution")}</td>
                              <td>
                                {value(pair, "proposed_event_external_id") || "-"} / {value(
                                  pair,
                                  "proposed_ticket_type_external_id"
                                ) || "-"}
                              </td>
                              <td>{value(pair, "pending_line_count")} / {value(pair, "quantity")}</td>
                              <td>{value(pair, "eligible_line_count")}</td>
                              <td>{value(pair, "deferred_line_count")}</td>
                              <td>{value(pair, "conflicting_line_count")}</td>
                              <td>{value(pair, "already_mapped_line_count")}</td>
                              <td class="font-mono">
                                {inspect(value(pair, "source_tickera_event_id_distribution"))}
                              </td>
                            </tr>
                          </tbody>
                        </table>
                      </div>
                      <div class="grid gap-3 md:grid-cols-3 text-xs">
                        <div>
                          <h4 class="font-semibold">Order statuses</h4>
                          <pre>{inspect(value(impact, "by_order_status"))}</pre>
                        </div>
                        <div>
                          <h4 class="font-semibold">Mapping statuses</h4>
                          <pre>{inspect(value(impact, "by_mapping_status"))}</pre>
                        </div>
                        <div>
                          <h4 class="font-semibold">Eligibility</h4>
                          <pre>{inspect(value(impact, "eligibility"))}</pre>
                        </div>
                      </div>
                      <div :if={value(impact, "warnings") != []}>
                        <h4 class="font-semibold">Warnings</h4>
                        <ul class="mt-1 list-disc pl-5 font-mono text-xs">
                          <li :for={warning <- value(impact, "warnings") || []}>
                            {value(warning, "code")} — product {value(warning, "woo_product_id")} /
                            variation {value(warning, "woo_variation_id") || "-"}
                          </li>
                        </ul>
                      </div>
                    </div>
                  </section>

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

                  <div :if={
                    mapping_conflict_rows(@mapping_conflicts, run.id) != [] or
                      mapping_conflict_error(@mapping_conflict_errors, run.id)
                  }>
                    <h3 class="mb-2 text-xs font-semibold uppercase text-base-content/70">
                      Mapping conflict resolution
                    </h3>
                    <div
                      :if={mapping_conflict_error(@mapping_conflict_errors, run.id)}
                      class="alert alert-warning mb-3 py-2 text-xs"
                    >
                      {mapping_conflict_error(@mapping_conflict_errors, run.id)}
                    </div>
                    <div
                      :if={mapping_conflict_rows(@mapping_conflicts, run.id) != []}
                      class="overflow-x-auto rounded border border-base-300 bg-base-100"
                    >
                      <table class="table table-zebra min-w-full text-xs">
                        <thead class="bg-base-200 text-left text-[0.65rem] font-semibold uppercase text-base-content/70">
                          <tr>
                            <th class="px-2 py-2">Run id</th>
                            <th class="px-2 py-2">Woo product ID</th>
                            <th class="px-2 py-2">Woo variation ID</th>
                            <th class="px-2 py-2">Feed Tickera event ID</th>
                            <th class="px-2 py-2">Mapped event</th>
                            <th class="px-2 py-2">Mapped external event ID</th>
                            <th class="px-2 py-2">Mapped ticket type</th>
                            <th class="px-2 py-2">Current active mapping id</th>
                            <th class="px-2 py-2">order_item_count</th>
                            <th class="px-2 py-2">Reason</th>
                            <th class="px-2 py-2">Action</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr :for={conflict <- mapping_conflict_rows(@mapping_conflicts, run.id)}>
                            <td class="px-2 py-2 font-mono">{conflict.run_id}</td>
                            <td class="px-2 py-2 font-mono">{conflict.woo_product_id}</td>
                            <td class="px-2 py-2 font-mono">
                              {display_value(conflict.woo_variation_id)}
                            </td>
                            <td class="px-2 py-2 font-mono">
                              {display_value(conflict.feed_tickera_event_id)}
                            </td>
                            <td class="px-2 py-2">{display_value(conflict.mapped_event_name)}</td>
                            <td class="px-2 py-2 font-mono">
                              {display_value(conflict.mapped_event_external_event_id)}
                            </td>
                            <td class="px-2 py-2">
                              {display_value(conflict.mapped_ticket_type_name)}
                            </td>
                            <td class="px-2 py-2 font-mono">
                              {display_value(conflict.mapping_id)}
                            </td>
                            <td class="px-2 py-2 font-mono">{conflict.order_item_count}</td>
                            <td class="px-2 py-2 font-mono">{conflict.reason}</td>
                            <td class="px-2 py-2">
                              <button
                                :if={conflict.resolution_status == :safe}
                                type="button"
                                phx-click="deactivate_stale_mapping"
                                phx-value-run_id={conflict.run_id}
                                phx-value-dry_run_hash={conflict.dry_run_hash}
                                phx-value-woo_product_id={conflict.woo_product_id}
                                phx-value-woo_variation_id={conflict.woo_variation_id || ""}
                                class="btn btn-warning btn-xs cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-warning/60 focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"
                              >
                                Deactivate stale mapping
                              </button>
                              <form
                                :if={conflict.reason == :order_history_exists}
                                phx-submit="cutover_stale_mapping"
                                class="flex min-w-80 flex-col gap-2"
                              >
                                <input type="hidden" name="run_id" value={conflict.run_id} />
                                <input
                                  type="hidden"
                                  name="dry_run_hash"
                                  value={conflict.dry_run_hash}
                                />
                                <input
                                  type="hidden"
                                  name="woo_product_id"
                                  value={conflict.woo_product_id}
                                />
                                <input
                                  type="hidden"
                                  name="woo_variation_id"
                                  value={conflict.woo_variation_id || ""}
                                />
                                <input
                                  type="hidden"
                                  name="stale_mapped_event_external_id"
                                  value={conflict.mapped_event_external_event_id}
                                />
                                <input
                                  type="hidden"
                                  name="feed_tickera_event_id"
                                  value={conflict.feed_tickera_event_id}
                                />
                                <input
                                  type="text"
                                  name="confirmation"
                                  class="input input-bordered input-xs bg-base-200 font-mono text-[0.65rem]"
                                  placeholder={
                                    cutover_confirmation_placeholder(
                                      conflict.woo_product_id,
                                      conflict.woo_variation_id,
                                      conflict.mapped_event_external_event_id,
                                      conflict.feed_tickera_event_id
                                    )
                                  }
                                />
                                <button type="submit" class="btn btn-warning btn-xs">
                                  Review cutover
                                </button>
                              </form>
                              <span
                                :if={
                                  conflict.resolution_status != :safe and
                                    conflict.reason != :order_history_exists
                                }
                                class="badge badge-outline"
                              >
                                {conflict.reason}
                              </span>
                            </td>
                          </tr>
                        </tbody>
                      </table>
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

      <section class="mt-8 rounded-lg border border-base-300 bg-base-100 p-4">
        <h2 class="mb-3 text-sm font-semibold text-base-content">
          Confirmed order attribution correction
        </h2>
        <div :if={@order_correction_error} class="alert alert-warning mb-3 py-2 text-xs">
          {@order_correction_error}
        </div>
        <div :if={@order_correction_preview} class="overflow-x-auto">
          <table class="table table-zebra min-w-full text-xs">
            <thead class="bg-base-200 text-left text-[0.65rem] font-semibold uppercase text-base-content/70">
              <tr>
                <th class="px-2 py-2">Woo order ID</th>
                <th class="px-2 py-2">Woo product ID</th>
                <th class="px-2 py-2">Woo variation ID</th>
                <th class="px-2 py-2">Quantity</th>
                <th class="px-2 py-2">Current event external ID</th>
                <th class="px-2 py-2">Target event external ID</th>
                <th class="px-2 py-2">Current ticket type</th>
                <th class="px-2 py-2">Target ticket type</th>
                <th class="px-2 py-2">Order item ID</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td class="px-2 py-2 font-mono">{@order_correction_preview.woo_order_id}</td>
                <td class="px-2 py-2 font-mono">{@order_correction_preview.woo_product_id}</td>
                <td class="px-2 py-2 font-mono">{@order_correction_preview.woo_variation_id}</td>
                <td class="px-2 py-2 font-mono">{@order_correction_preview.quantity}</td>
                <td class="px-2 py-2 font-mono">
                  {@order_correction_preview.current_event_external_id}
                </td>
                <td class="px-2 py-2 font-mono">
                  {@order_correction_preview.target_event_external_id}
                </td>
                <td class="px-2 py-2">{@order_correction_preview.current_ticket_type_name}</td>
                <td class="px-2 py-2">{@order_correction_preview.target_ticket_type_name}</td>
                <td class="px-2 py-2 font-mono">{@order_correction_preview.order_item_id}</td>
              </tr>
            </tbody>
          </table>
          <form phx-submit="correct_order_attribution" class="mt-3 flex flex-wrap gap-2">
            <input
              type="text"
              name="confirmation"
              class="input input-bordered input-sm min-w-96 bg-base-200 font-mono text-xs"
              placeholder="CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120"
            />
            <button type="submit" class="btn btn-warning btn-sm">
              Correct order attribution
            </button>
          </form>
        </div>
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

  defp load_catalog_change_targets do
    CatalogChangePendingTarget
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(50)
    |> Ash.read(domain: Ingestion)
    |> case do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  defp load_active_run(socket, form) do
    case form["source_system_id"] do
      source_system_id when is_binary(source_system_id) and source_system_id != "" ->
        case TickeraCatalogSync.active_run_for_source(source_system_id,
               actor: socket.assigns.current_user
             ) do
          {:ok, active_run} ->
            form_state =
              Map.put(
                socket.assigns.form_state,
                :queue_enabled?,
                is_nil(active_run) and socket.assigns.form_state.queue_enabled?
              )

            socket |> assign(:active_run, active_run) |> assign(:form_state, form_state)

          _other ->
            socket
        end

      _other ->
        assign(socket, :active_run, nil)
    end
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

  defp load_runs(socket, requested_run_id) do
    case TickeraCatalogSync.list_runs(actor: socket.assigns.current_user, summary_only?: true) do
      {:ok, runs} ->
        selected_summary = select_run(runs, requested_run_id)

        {selected_run, previews} =
          load_selected_preview(selected_summary, socket.assigns.current_user)

        {mapping_conflicts, mapping_conflict_errors} =
          load_selected_mapping_conflicts(selected_run, previews, socket.assigns.current_user)

        socket
        |> sync_run_subscriptions(runs, selected_run)
        |> assign(:runs, runs)
        |> assign(:selected_run_id, selected_run && selected_run.id)
        |> assign(:selected_run, selected_run)
        |> assign(:previews, previews)
        |> assign(:mapping_conflicts, mapping_conflicts)
        |> assign(:mapping_conflict_errors, mapping_conflict_errors)

      {:error, _reason} ->
        socket
        |> sync_run_subscriptions([], nil)
        |> assign(:runs, [])
        |> assign(:selected_run_id, nil)
        |> assign(:selected_run, nil)
        |> assign(:previews, %{})
        |> assign(:mapping_conflicts, %{})
        |> assign(:mapping_conflict_errors, %{})
    end
  end

  defp reload_selected_run(socket), do: load_runs(socket, socket.assigns.selected_run_id)

  defp load_order_correction_preview(socket) do
    case correction_source_system_id(socket) do
      nil ->
        socket
        |> assign(:order_correction_preview, nil)
        |> assign(:order_correction_error, nil)

      source_system_id ->
        case OrderAttributionCorrection.preview_confirmed_order_113834(source_system_id,
               actor: socket.assigns.current_user
             ) do
          {:ok, preview} ->
            socket
            |> assign(:order_correction_preview, preview)
            |> assign(:order_correction_error, nil)

          {:error, reason} ->
            socket
            |> assign(:order_correction_preview, nil)
            |> assign(:order_correction_error, Atom.to_string(reason))
        end
    end
  end

  defp correction_source_system_id(socket) do
    selected =
      socket.assigns.form
      |> Map.get("source_system_id", "")
      |> to_string()
      |> String.trim()

    cond do
      selected != "" ->
        selected

      match?([_source | _rest], socket.assigns.source_systems) ->
        socket.assigns.source_systems |> hd() |> Map.fetch!(:id)

      true ->
        nil
    end
  end

  defp select_run(runs, requested_run_id) do
    Enum.find(runs, &(&1.id == requested_run_id)) || List.first(runs)
  end

  defp load_selected_preview(nil, _current_user), do: {nil, %{}}

  defp load_selected_preview(run, current_user) do
    case TickeraCatalogSync.get_run_preview(run.id, actor: current_user) do
      {:ok, %{run: loaded_run, preview: preview}}
      when is_map(preview) and loaded_run.id == run.id and
             loaded_run.dry_run_hash == run.dry_run_hash ->
        {loaded_run, %{run.id => preview}}

      _other ->
        {run, %{run.id => %{}}}
    end
  end

  defp sync_run_subscriptions(socket, runs, selected_run) do
    if connected?(socket) do
      desired_ids =
        runs
        |> Enum.filter(&active_run?/1)
        |> Enum.map(& &1.id)
        |> maybe_add_selected_run(selected_run)
        |> MapSet.new()

      current_ids = socket.assigns.subscribed_run_ids

      current_ids
      |> MapSet.difference(desired_ids)
      |> Enum.each(&Phoenix.PubSub.unsubscribe(EventSales.PubSub, PubSub.topic(&1)))

      desired_ids
      |> MapSet.difference(current_ids)
      |> Enum.each(&PubSub.subscribe/1)

      assign(socket, :subscribed_run_ids, desired_ids)
    else
      socket
    end
  end

  defp active_run?(run),
    do: run.status in [:queued, :discovering, :retry_scheduled, :dry_run_ready, :applying]

  defp maybe_add_selected_run(run_ids, nil), do: run_ids
  defp maybe_add_selected_run(run_ids, selected_run), do: [selected_run.id | run_ids]

  defp load_selected_mapping_conflicts(nil, _previews, _current_user), do: {%{}, %{}}

  defp load_selected_mapping_conflicts(run, previews, current_user) do
    merge_mapping_conflict_result({%{}, %{}}, run, preview(previews, run.id), current_user)
  end

  defp merge_mapping_conflict_result({conflicts, errors}, run, preview, current_user) do
    case mapping_conflict_result(run, preview, current_user) do
      {:ok, rows} ->
        {Map.put(conflicts, run.id, rows), errors}

      {:error, reason} ->
        {Map.put(conflicts, run.id, []), Map.put(errors, run.id, Atom.to_string(reason))}
    end
  end

  defp mapping_conflict_result(run, preview, current_user) do
    if has_mapping_conflict_finding?(preview) do
      MappingConflictResolver.list_conflicts(run.id, run.dry_run_hash, actor: current_user)
    else
      {:ok, []}
    end
  end

  defp has_mapping_conflict_finding?(preview) do
    Enum.any?(findings(preview), fn finding ->
      value(finding, "severity") in [:blocking, "blocking"] and
        value(finding, "code") in [:existing_mapping_conflict, "existing_mapping_conflict"]
    end)
  end

  defp mapping_conflict_rows(conflicts, run_id), do: Map.get(conflicts, run_id, [])
  defp mapping_conflict_error(errors, run_id), do: Map.get(errors, run_id)

  defp cutover_confirmation_placeholder(product_id, variation_id, stale_event_id, feed_event_id) do
    "CUTOVER #{product_id}/#{variation_id || "none"} FROM #{stale_event_id} TO #{feed_event_id}"
  end

  defp preview(previews, run_id), do: Map.get(previews, run_id, %{})

  defp selected_run_list(nil), do: []
  defp selected_run_list(run), do: [run]

  defp selected_run_path(run_id), do: ~p"/admin/catalog-sync?run_id=#{run_id}"

  defp close_revoke_modal(socket) do
    socket
    |> assign(:revoke_modal_run_id, nil)
    |> assign(:revoke_form, revoke_form(%{}))
  end

  defp revoke_form(params) when is_map(params) do
    %{
      "cancellation_reason_code" => Map.get(params, "cancellation_reason_code", ""),
      "cancellation_reason_details" => Map.get(params, "cancellation_reason_details", "")
    }
  end

  defp cancellation_reason_options do
    [
      {"source_changed", "Source catalog changed after snapshot"},
      {"incorrect_scope", "Incorrect scope selected"},
      {"unexpected_changes", "Proposed changes are unexpected or too broad"},
      {"superseded", "Superseded by another dry-run"},
      {"operator_error", "Operator error"},
      {"other", "Other"}
    ]
  end

  defp cancellation_reason_label(reason_code) do
    reason = reason_code && Atom.to_string(reason_code)

    cancellation_reason_options()
    |> Enum.find_value("Unknown reason", fn
      {^reason, label} -> label
      _option -> nil
    end)
  end

  defp cancelled_by_name(%{cancelled_by_user: %{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp cancelled_by_name(_run), do: "Admin user"

  defp source_name(source_systems, source_system_id) do
    source_systems
    |> Enum.find(&(&1.id == source_system_id))
    |> case do
      %{name: name} when is_binary(name) and name != "" -> name
      _source -> "Unavailable"
    end
  end

  defp scope_label(%{"kind" => "wordpress_feed", "mode" => "full"}),
    do: "WordPress feed full catalog"

  defp scope_label(%{"kind" => "wordpress_feed", "product_id" => product_id}),
    do: "WordPress feed product #{product_id}"

  defp scope_label(%{"kind" => "wordpress_feed", "variation_id" => variation_id}),
    do: "WordPress feed variation #{variation_id}"

  defp scope_label(%{"kind" => "wordpress_feed", "event_id" => event_id}),
    do: "WordPress feed event #{event_id}"

  defp scope_label(%{"kind" => "wordpress_feed", "updated_since" => updated_since}),
    do: "WordPress feed updated since #{updated_since}"

  defp scope_label(%{"kind" => "manual_rows"}), do: "Sanitized manual rows"

  defp scope_label(%{"kind" => "woo_product", "product_id" => product_id}),
    do: "WooCommerce product #{product_id}"

  defp scope_label(_scope), do: "Unavailable"

  defp change_count(preview, key), do: preview |> list(key) |> length()

  defp finding_count(preview, severity) do
    Enum.count(findings(preview), &(display_value(value(&1, "severity")) == severity))
  end

  defp historical_impact(preview) when is_map(preview), do: value(preview, "historical_impact")
  defp historical_impact(_preview), do: nil

  defp impact_total(impact, key) do
    impact
    |> value("totals")
    |> case do
      totals when is_map(totals) -> value(totals, key) || 0
      _ -> 0
    end
  end

  defp impact_entries(impact, key) do
    case value(impact, key) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  defp validate_selected_apply(socket, run_id, dry_run_hash) do
    run = socket.assigns.selected_run
    run_preview = run && preview(socket.assigns.previews, run.id)

    if run && run.id == run_id && run.dry_run_hash == dry_run_hash &&
         apply_enabled?(run, run_preview) do
      :ok
    else
      {:error, :run_not_ready}
    end
  end

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

  defp active_run_message,
    do:
      "A Catalog Sync run is active or awaiting review. Apply or revoke the existing run before queueing another."

  defp status_label(:queued), do: "Queued"
  defp status_label(:discovering), do: "Discovering"
  defp status_label(:retry_scheduled), do: "Retry scheduled"
  defp status_label(:dry_run_ready), do: "Ready for review"
  defp status_label(:applying), do: "Applying"
  defp status_label(:applied), do: "Applied"
  defp status_label(:failed), do: "Failed"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(_status), do: "Unknown"

  defp status_spinner?(status), do: status in [:discovering, :applying]
  defp status_clock?(status), do: status in [:queued, :retry_scheduled]

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
