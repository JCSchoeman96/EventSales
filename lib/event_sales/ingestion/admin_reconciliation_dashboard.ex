defmodule EventSales.Ingestion.AdminReconciliationDashboard do
  @moduledoc """
  Admin read/write facade for Tickera/Woo reconciliation findings and runs.

  Web modules must call this facade only. It delegates to ingestion workers and
  durable state modules without exposing forbidden names to `event_sales_web`.

  ## Manual actions

  - `queue_attendee_sync/2` — refresh **local Tickera attendee snapshots** only
  - `queue_reconciliation/2` — compare **existing local snapshots** against Woo/EventSales
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Ingestion

  alias EventSales.Ingestion.Resources.{
    TickeraAttendeeSyncRun,
    TickeraReconciliationFinding,
    TickeraReconciliationRun
  }

  alias EventSales.Ingestion.{
    TickeraAttendeeSyncQueue,
    TickeraEventSources,
    TickeraReconciliationFindings,
    TickeraReconciliationRuns
  }

  alias EventSales.Sales
  alias EventSales.Sales.Resources.Order

  @default_per_page 25
  @max_per_page 50
  @export_max_rows 10_000
  @export_page_size 500

  @safe_detail_keys ~w(
    delta
    unmapped_count
    latest_seen_at
    stale_after_hours
    latest_completed_sync_run_id
    tickera_ticket_type
    tickera_ticket_type_id
    reason
    woo_quantity
  )a

  @recommended_actions %{
    woo_paid_missing_tickera:
      "Verify Tickera attendee registration exists for each paid Woo sale.",
    tickera_paid_extra:
      "Confirm Woo order status; investigate extra Tickera attendees without matching sales.",
    quantity_mismatch:
      "Compare paid Woo line quantities with Tickera attendee counts for the ticket type.",
    payment_status_mismatch:
      "Review Woo order status and Tickera payment status for the same sale.",
    ticket_type_mismatch: "Check product/ticket mapping between Woo and Tickera labels.",
    stale_tickera_snapshot:
      "Queue a Tickera attendee sync to refresh local snapshots before reconciling again.",
    unmapped_woo_order_item: "Map Woo products to ticket types in catalog mappings.",
    no_tickera_source: "Configure an active Tickera event source for this event.",
    no_tickera_snapshots: "Queue a Tickera attendee sync to import attendee snapshots."
  }

  @type page :: %{
          page: pos_integer(),
          per_page: pos_integer(),
          has_next?: boolean(),
          has_previous?: boolean()
        }

  @spec snapshot(keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(opts \\ []) do
    with :ok <- authorize(opts) do
      filter_opts = filter_opts_from(opts)

      {:ok,
       %{
         open_count: count_findings(filter_opts, status: :open),
         critical_count: count_findings(filter_opts, severity: :critical, status: :open),
         warning_count: count_findings(filter_opts, severity: :warning, status: :open),
         info_count: count_findings(filter_opts, severity: :info, status: :open),
         latest_reconciliation_run: latest_reconciliation_run(filter_opts),
         latest_attendee_sync_run: latest_attendee_sync_run(filter_opts),
         scoped_event_id: Keyword.get(filter_opts, :event_id)
       }}
    end
  end

  @spec list_runs(keyword()) :: {:ok, %{rows: [map()], page: page()}} | {:error, term()}
  def list_runs(opts \\ []) do
    with :ok <- authorize(opts),
         %{page: page, per_page: per_page, offset: offset} <- pagination(opts),
         {:ok, runs} <- read_runs(opts, per_page + 1, offset) do
      {visible, has_next?} = split_page(runs, per_page)

      {:ok,
       %{
         rows: Enum.map(visible, &run_row/1),
         page: page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec list_findings(keyword()) :: {:ok, %{rows: [map()], page: page()}} | {:error, term()}
  def list_findings(opts \\ []) do
    with :ok <- authorize(opts),
         %{page: page, per_page: per_page, offset: offset} <- pagination(opts),
         filter_opts <- filter_opts_from(opts),
         {:ok, findings} <-
           TickeraReconciliationFindings.list_filtered(
             filter_opts
             |> Keyword.put(:limit, per_page + 1)
             |> Keyword.put(:offset, offset)
           ) do
      {visible, has_next?} = split_page(findings, per_page)
      lookups = build_lookups(visible)

      {:ok,
       %{
         rows: Enum.map(visible, &finding_row(&1, lookups)),
         page: page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec get_finding(Ecto.UUID.t() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_finding(id, opts \\ []) do
    with :ok <- authorize(opts),
         {:ok, finding} <- TickeraReconciliationFindings.get_finding(id, actor: actor(opts)) do
      {:ok, finding_row(finding, build_lookups([finding]))}
    end
  end

  @spec finding_row(TickeraReconciliationFinding.t(), map()) :: map()
  def finding_row(%TickeraReconciliationFinding{} = finding, lookups \\ %{}) do
    %{
      id: finding.id,
      tickera_reconciliation_run_id: finding.tickera_reconciliation_run_id,
      event_id: finding.event_id,
      event_name: Map.get(lookups.events, finding.event_id),
      source_label: source_label(finding),
      finding_type: finding.finding_type,
      finding_type_label: humanize_atom(finding.finding_type),
      severity: finding.severity,
      status: finding.status,
      ticket_type_id: finding.ticket_type_id,
      ticket_type_name: Map.get(lookups.ticket_types, finding.ticket_type_id),
      order_id: finding.order_id,
      order_item_id: finding.order_item_id,
      woo_order_id: Map.get(lookups.woo_order_ids, finding.order_id),
      woo_quantity: finding.woo_quantity,
      tickera_quantity: finding.tickera_quantity,
      woo_order_status: finding.woo_order_status,
      tickera_payment_status: finding.tickera_payment_status,
      ticket_code: finding.ticket_code,
      checksum: finding.checksum,
      details: sanitize_details(finding.details),
      recommended_action: Map.get(@recommended_actions, finding.finding_type, "Review manually."),
      resolution_reason: finding.resolution_reason,
      resolved_at: finding.resolved_at,
      first_seen_at: finding.first_seen_at,
      last_seen_at: finding.last_seen_at,
      inserted_at: finding.inserted_at
    }
  end

  @spec resolve_finding(Ecto.UUID.t() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_finding(id, attrs, opts) do
    with :ok <- authorize(opts),
         {:ok, finding} <- TickeraReconciliationFindings.get_finding(id, actor: actor(opts)),
         {:ok, updated} <-
           TickeraReconciliationFindings.resolve(finding, attrs, actor: actor(opts)) do
      {:ok, finding_row(updated, build_lookups([updated]))}
    end
  end

  @spec ignore_finding(Ecto.UUID.t() | String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ignore_finding(id, attrs, opts) do
    with :ok <- authorize(opts),
         {:ok, finding} <- TickeraReconciliationFindings.get_finding(id, actor: actor(opts)),
         {:ok, updated} <-
           TickeraReconciliationFindings.ignore(finding, attrs, actor: actor(opts)) do
      {:ok, finding_row(updated, build_lookups([updated]))}
    end
  end

  @spec reopen_finding(Ecto.UUID.t() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reopen_finding(id, opts) do
    with :ok <- authorize(opts),
         {:ok, finding} <- TickeraReconciliationFindings.get_finding(id, actor: actor(opts)),
         {:ok, updated} <- TickeraReconciliationFindings.reopen(finding, actor: actor(opts)) do
      {:ok, finding_row(updated, build_lookups([updated]))}
    end
  end

  @doc """
  Queues a manual Tickera attendee snapshot sync (refreshes local snapshots only).
  """
  @spec queue_attendee_sync(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, %{sync_run: struct(), job: Oban.Job.t()}}
          | {:error, :forbidden | :inactive_source | :enqueue_failed | :not_found | term()}
  def queue_attendee_sync(event_id, opts \\ []) do
    audit_attrs = Keyword.get(opts, :audit_attrs, %{})

    with :ok <- authorize(opts),
         {:ok, event_uuid} <- cast_uuid(event_id),
         {:ok, source} <- active_source_for_event(event_uuid, opts),
         {:ok, result} <-
           TickeraAttendeeSyncQueue.queue_manual(source, %{}, actor: actor(opts)),
         {:ok, _audit} <- audit_attendee_sync(result.sync_run, audit_attrs) do
      {:ok, result}
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        {:error, :not_found}

      other ->
        other
    end
  end

  @doc """
  Queues a manual reconciliation run (compares local snapshots to Woo/EventSales).
  """
  @spec queue_reconciliation(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, %{reconciliation_run: struct(), job: Oban.Job.t()}}
          | {:error, :forbidden | :enqueue_failed | :not_found | term()}
  def queue_reconciliation(event_id, opts \\ []) do
    audit_attrs = Keyword.get(opts, :audit_attrs, %{})

    with :ok <- authorize(opts),
         {:ok, event_uuid} <- cast_uuid(event_id),
         {:ok, result} <-
           TickeraReconciliationRuns.queue_manual_for_event(event_uuid, actor: actor(opts)),
         {:ok, _audit} <- audit_reconciliation_run(result.reconciliation_run, audit_attrs) do
      {:ok, result}
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        {:error, :not_found}

      other ->
        other
    end
  end

  @spec stream_findings_for_export(keyword()) ::
          {:ok, Enumerable.t(), boolean()} | {:error, term()}
  def stream_findings_for_export(opts \\ []) do
    with :ok <- authorize(opts) do
      filter_opts = filter_opts_from(opts)
      limit = export_row_limit(opts)

      stream =
        Stream.resource(
          fn -> 0 end,
          fn
            :halt ->
              {:halt, :halt}

            offset when offset >= limit ->
              {:halt, :halt}

            offset ->
              export_page(filter_opts, limit, offset)
          end,
          fn _state -> :ok end
        )

      total =
        case TickeraReconciliationFindings.count_filtered(filter_opts) do
          {:ok, count} -> count
          {:error, _} -> 0
        end

      {:ok, stream, total > limit}
    end
  end

  @spec filter_opts_from(keyword()) :: keyword()
  def filter_opts_from(opts) do
    []
    |> maybe_put_filter(:event_id, opts[:event_id])
    |> maybe_put_filter(:tickera_event_source_id, opts[:tickera_event_source_id])
    |> maybe_put_filter(:tickera_reconciliation_run_id, opts[:tickera_reconciliation_run_id])
    |> maybe_put_filter(:ticket_type_id, opts[:ticket_type_id])
    |> maybe_put_filter_atom(:status, opts[:status])
    |> maybe_put_filter_atom(:severity, opts[:severity])
    |> maybe_put_filter_atom(:finding_type, opts[:finding_type])
    |> maybe_put_filter(:woo_order_status, opts[:woo_order_status])
    |> maybe_put_filter(:tickera_payment_status, opts[:tickera_payment_status])
    |> maybe_put_filter_datetime(:last_seen_from, opts[:last_seen_from], :start_of_day)
    |> maybe_put_filter_datetime(:last_seen_to, opts[:last_seen_to], :end_of_day)
    |> Keyword.put(:actor, actor(opts))
  end

  @doc false
  @spec export_row_limit(keyword()) :: pos_integer()
  def export_row_limit(opts \\ []) do
    opts
    |> Keyword.get(:limit, @export_max_rows)
    |> normalize_export_limit()
  end

  defp normalize_export_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @export_max_rows)
  end

  defp normalize_export_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> normalize_export_limit(parsed)
      _other -> @export_max_rows
    end
  end

  defp normalize_export_limit(_limit), do: @export_max_rows

  defp active_source_for_event(event_uuid, opts) do
    case TickeraEventSources.get_source_for_event(event_uuid, actor: actor(opts)) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, source} -> {:ok, source}
      other -> other
    end
  end

  defp export_page(filter_opts, limit, offset) do
    page_size = min(@export_page_size, limit - offset)

    case TickeraReconciliationFindings.list_filtered(
           filter_opts
           |> Keyword.put(:limit, page_size + 1)
           |> Keyword.put(:offset, offset)
         ) do
      {:ok, []} ->
        {:halt, :halt}

      {:ok, findings} ->
        export_page_rows(findings, page_size, limit, offset)

      {:error, reason} ->
        raise "export failed: #{inspect(reason)}"
    end
  end

  defp export_page_rows(findings, page_size, limit, offset) do
    last_page? = length(findings) <= page_size
    visible = findings |> Enum.take(page_size) |> Enum.take(limit - offset)
    lookups = build_lookups(visible)
    rows = Enum.map(visible, &export_row(&1, lookups))
    next_offset = offset + length(visible)

    cond do
      visible == [] -> {:halt, :halt}
      last_page? or next_offset >= limit -> {rows, :halt}
      true -> {rows, next_offset}
    end
  end

  defp export_row(%TickeraReconciliationFinding{} = finding, lookups) do
    row = finding_row(finding, lookups)

    %{
      "event" => Map.get(row, :event_name) || Map.get(row, :event_id),
      "source" => Map.get(row, :source_label),
      "run_id" => Map.get(row, :tickera_reconciliation_run_id),
      "finding_type" => Map.get(row, :finding_type),
      "severity" => Map.get(row, :severity),
      "status" => Map.get(row, :status),
      "ticket_type" => Map.get(row, :ticket_type_name) || Map.get(row, :ticket_type_id),
      "woo_quantity" => Map.get(row, :woo_quantity),
      "tickera_quantity" => Map.get(row, :tickera_quantity),
      "woo_order_status" => Map.get(row, :woo_order_status),
      "tickera_payment_status" => Map.get(row, :tickera_payment_status),
      "ticket_code" => Map.get(row, :ticket_code),
      "checksum" => Map.get(row, :checksum),
      "created_at" => Map.get(row, :inserted_at),
      "last_seen_at" => Map.get(row, :last_seen_at),
      "resolution_reason" => Map.get(row, :resolution_reason)
    }
  end

  defp count_findings(filter_opts, extra_filters) do
    opts =
      filter_opts
      |> Keyword.merge(extra_filters)
      |> Keyword.delete(:offset)
      |> Keyword.delete(:limit)

    case TickeraReconciliationFindings.count_filtered(opts) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  defp latest_reconciliation_run(filter_opts) do
    query = TickeraReconciliationRun

    query =
      case Keyword.get(filter_opts, :event_id) do
        nil -> query
        event_id -> Ash.Query.filter(query, event_id == ^event_id)
      end

    case query
         |> Ash.Query.sort(inserted_at: :desc, id: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, nil} -> nil
      {:ok, run} -> run_row(run)
      {:error, _} -> nil
    end
  end

  defp latest_attendee_sync_run(filter_opts) do
    query = TickeraAttendeeSyncRun

    query =
      case Keyword.get(filter_opts, :event_id) do
        nil -> query
        event_id -> Ash.Query.filter(query, event_id == ^event_id)
      end

    case query
         |> Ash.Query.sort(inserted_at: :desc, id: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, nil} -> nil
      {:ok, run} -> attendee_sync_run_row(run)
      {:error, _} -> nil
    end
  end

  defp read_runs(opts, limit, offset) do
    query = TickeraReconciliationRun

    query =
      case cast_uuid(Keyword.get(opts, :event_id)) do
        {:ok, event_id} -> Ash.Query.filter(query, event_id == ^event_id)
        _ -> query
      end

    query = apply_run_status_filter(query, Keyword.get(opts, :status))

    query
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(domain: Ingestion)
  end

  defp run_row(%TickeraReconciliationRun{} = run) do
    %{
      id: run.id,
      event_id: run.event_id,
      status: run.status,
      requested_via: run.requested_via,
      started_at: run.started_at,
      finished_at: run.finished_at,
      last_error: run.last_error,
      findings_open_count: run.findings_open_count,
      critical_count: run.critical_count,
      warning_count: run.warning_count,
      info_count: run.info_count,
      inserted_at: run.inserted_at
    }
  end

  defp attendee_sync_run_row(%TickeraAttendeeSyncRun{} = run) do
    %{
      id: run.id,
      event_id: run.event_id,
      status: run.status,
      requested_via: run.requested_via,
      started_at: run.started_at,
      finished_at: run.finished_at,
      last_error: run.last_error,
      inserted_at: run.inserted_at
    }
  end

  defp build_lookups(findings) do
    event_ids = findings |> Enum.map(& &1.event_id) |> Enum.uniq()

    ticket_type_ids =
      findings |> Enum.map(& &1.ticket_type_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    order_ids = findings |> Enum.map(& &1.order_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      events: load_event_names(event_ids),
      ticket_types: load_ticket_type_names(ticket_type_ids),
      woo_order_ids: load_woo_order_ids(order_ids)
    }
  end

  defp load_event_names([]), do: %{}

  defp load_event_names(event_ids) do
    Event
    |> Ash.Query.filter(id in ^event_ids)
    |> Ash.read!(domain: Catalog)
    |> Map.new(&{&1.id, &1.name})
  end

  defp load_ticket_type_names([]), do: %{}

  defp load_ticket_type_names(ticket_type_ids) do
    TicketType
    |> Ash.Query.filter(id in ^ticket_type_ids)
    |> Ash.read!(domain: Catalog)
    |> Map.new(&{&1.id, &1.name})
  end

  defp load_woo_order_ids([]), do: %{}

  defp load_woo_order_ids(order_ids) do
    Order
    |> Ash.Query.filter(id in ^order_ids)
    |> Ash.read!(domain: Sales)
    |> Map.new(&{&1.id, &1.woo_order_id})
  end

  defp source_label(%TickeraReconciliationFinding{tickera_event_source_id: nil}), do: "no source"

  defp source_label(%TickeraReconciliationFinding{tickera_event_source_id: source_id}),
    do: source_id

  defp sanitize_details(details) when is_map(details) do
    details
    |> Enum.filter(fn {key, _value} ->
      key = if is_atom(key), do: key, else: safe_string_to_atom(key)
      key in @safe_detail_keys
    end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp sanitize_details(_other), do: %{}

  defp safe_string_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp audit_attendee_sync(%TickeraAttendeeSyncRun{} = run, audit_attrs) do
    metadata =
      audit_attrs
      |> Map.get(:metadata, %{})
      |> Map.merge(%{
        "event_id" => run.event_id,
        "sync_run_id" => run.id,
        "requested_via" => "manual",
        "result" => "queued"
      })

    audit_attrs
    |> Map.drop([:metadata])
    |> Map.put(:subject_type, "tickera_attendee_sync_run")
    |> Map.put(:subject_id, run.id)
    |> Map.put(:event_id, run.event_id)
    |> Map.put(:metadata, metadata)
    |> then(&AuditLogger.tickera_attendee_sync_requested/1)
  end

  defp audit_reconciliation_run(%TickeraReconciliationRun{} = run, audit_attrs) do
    metadata =
      audit_attrs
      |> Map.get(:metadata, %{})
      |> Map.merge(%{
        "event_id" => run.event_id,
        "reconciliation_run_id" => run.id,
        "requested_via" => "manual",
        "result" => "queued"
      })

    audit_attrs
    |> Map.drop([:metadata])
    |> Map.put(:subject_type, "tickera_reconciliation_run")
    |> Map.put(:subject_id, run.id)
    |> Map.put(:event_id, run.event_id)
    |> Map.put(:metadata, metadata)
    |> then(&AuditLogger.tickera_reconciliation_run_requested/1)
  end

  defp authorize(opts) do
    if actor(opts) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp actor(opts), do: Keyword.get(opts, :actor)

  defp pagination(opts) do
    page =
      opts
      |> Keyword.get(:page, 1)
      |> normalize_positive_integer(1)

    per_page =
      opts
      |> Keyword.get(:per_page, @default_per_page)
      |> normalize_positive_integer(@default_per_page)
      |> min(@max_per_page)

    %{page: page, per_page: per_page, offset: (page - 1) * per_page}
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp split_page(rows, per_page) do
    {Enum.take(rows, per_page), length(rows) > per_page}
  end

  defp page_info(page, per_page, has_next?) do
    %{
      page: page,
      per_page: per_page,
      has_next?: has_next?,
      has_previous?: page > 1
    }
  end

  defp maybe_put_filter(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_filter_atom(opts, _key, value) when value in [nil, ""], do: opts

  defp maybe_put_filter_atom(opts, key, value) when is_atom(value),
    do: Keyword.put(opts, key, value)

  defp maybe_put_filter_atom(opts, key, value) when is_binary(value) do
    case parse_atom_filter(value, TickeraReconciliationFinding, key) do
      {:ok, atom} -> Keyword.put(opts, key, atom)
      _ -> opts
    end
  end

  defp maybe_put_filter_datetime(opts, _key, value, _boundary) when value in [nil, ""], do: opts

  defp maybe_put_filter_datetime(opts, key, %DateTime{} = value, _boundary),
    do: Keyword.put(opts, key, value)

  defp maybe_put_filter_datetime(opts, key, value, boundary) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(String.trim(value)),
         {:ok, datetime} <- boundary_datetime(date, boundary) do
      Keyword.put(opts, key, datetime)
    else
      _ -> opts
    end
  end

  defp boundary_datetime(date, :start_of_day) do
    {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
  rescue
    _ -> {:error, :invalid}
  end

  defp boundary_datetime(date, :end_of_day) do
    {:ok, DateTime.new!(date, ~T[23:59:59], "Etc/UTC")}
  rescue
    _ -> {:error, :invalid}
  end

  defp apply_run_status_filter(query, status) when status in [nil, ""], do: query

  defp apply_run_status_filter(query, status) when is_atom(status) do
    Ash.Query.filter(query, status == ^status)
  end

  defp apply_run_status_filter(query, status) when is_binary(status) do
    allowed = allowed_atoms(TickeraReconciliationRun, :status) |> Enum.map(&Atom.to_string/1)

    if status in allowed do
      Ash.Query.filter(query, status == ^String.to_existing_atom(status))
    else
      Ash.Query.filter(query, false)
    end
  end

  defp allowed_atoms(resource, attribute) do
    resource
    |> Ash.Resource.Info.attribute(attribute)
    |> Map.get(:constraints, [])
    |> Keyword.get(:one_of, [])
  end

  defp parse_atom_filter(value, resource, attribute) when is_binary(value) do
    allowed = allowed_atoms(resource, attribute)

    if value in Enum.map(allowed, &Atom.to_string/1) do
      {:ok, String.to_existing_atom(value)}
    else
      :invalid
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_uuid(value), do: cast_uuid(to_string(value))

  defp humanize_atom(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
  end
end
