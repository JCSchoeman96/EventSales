defmodule EventSales.Ingestion.TickeraReconciliationFindings do
  @moduledoc """
  Facade for durable Tickera/Woo reconciliation findings.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraReconciliationFinding

  @default_limit 100
  @max_limit 500
  @authorized_context %{tickera_state_authorized?: true, tickera_state_authorized: true}

  def list_for_event(event_id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraReconciliationFinding
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def list_for_run(run_id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraReconciliationFinding
      |> Ash.Query.filter(tickera_reconciliation_run_id == ^run_id)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_finding(id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      Ash.get(TickeraReconciliationFinding, id, domain: Ingestion)
    end
  end

  def list_filtered(opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraReconciliationFinding
      |> apply_filters(opts)
      |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.Query.offset(Keyword.get(opts, :offset, 0))
      |> Ash.read(domain: Ingestion)
    end
  end

  def count_filtered(opts \\ []) do
    with :ok <- authorize_read(opts) do
      TickeraReconciliationFinding
      |> apply_filters(opts)
      |> Ash.count(domain: Ingestion)
    end
  end

  defp apply_filters(query, opts) do
    query
    |> filter_uuid(:event_id, Keyword.get(opts, :event_id))
    |> filter_uuid(:tickera_event_source_id, Keyword.get(opts, :tickera_event_source_id))
    |> filter_uuid(
      :tickera_reconciliation_run_id,
      Keyword.get(opts, :tickera_reconciliation_run_id)
    )
    |> filter_uuid(:ticket_type_id, Keyword.get(opts, :ticket_type_id))
    |> filter_eq(:status, Keyword.get(opts, :status))
    |> filter_eq(:severity, Keyword.get(opts, :severity))
    |> filter_eq(:finding_type, Keyword.get(opts, :finding_type))
    |> filter_eq(:woo_order_status, Keyword.get(opts, :woo_order_status))
    |> filter_eq(:tickera_payment_status, Keyword.get(opts, :tickera_payment_status))
    |> filter_last_seen_from(Keyword.get(opts, :last_seen_from))
    |> filter_last_seen_to(Keyword.get(opts, :last_seen_to))
  end

  defp filter_uuid(query, _attr, value) when value in [nil, ""], do: query

  defp filter_uuid(query, :event_id, value),
    do: filter_uuid_field(query, value, :event_id)

  defp filter_uuid(query, :tickera_event_source_id, value),
    do: filter_uuid_field(query, value, :tickera_event_source_id)

  defp filter_uuid(query, :tickera_reconciliation_run_id, value),
    do: filter_uuid_field(query, value, :tickera_reconciliation_run_id)

  defp filter_uuid(query, :ticket_type_id, value),
    do: filter_uuid_field(query, value, :ticket_type_id)

  defp filter_uuid_field(query, value, :event_id) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> Ash.Query.filter(query, event_id == ^uuid)
      :error -> Ash.Query.filter(query, false)
    end
  end

  defp filter_uuid_field(query, value, :tickera_event_source_id) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> Ash.Query.filter(query, tickera_event_source_id == ^uuid)
      :error -> Ash.Query.filter(query, false)
    end
  end

  defp filter_uuid_field(query, value, :tickera_reconciliation_run_id) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> Ash.Query.filter(query, tickera_reconciliation_run_id == ^uuid)
      :error -> Ash.Query.filter(query, false)
    end
  end

  defp filter_uuid_field(query, value, :ticket_type_id) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> Ash.Query.filter(query, ticket_type_id == ^uuid)
      :error -> Ash.Query.filter(query, false)
    end
  end

  defp filter_eq(query, _attr, value) when value in [nil, ""], do: query

  defp filter_eq(query, :status, value) when is_atom(value),
    do: Ash.Query.filter(query, status == ^value)

  defp filter_eq(query, :severity, value) when is_atom(value),
    do: Ash.Query.filter(query, severity == ^value)

  defp filter_eq(query, :finding_type, value) when is_atom(value),
    do: Ash.Query.filter(query, finding_type == ^value)

  defp filter_eq(query, :woo_order_status, value) when is_binary(value),
    do: Ash.Query.filter(query, woo_order_status == ^value)

  defp filter_eq(query, :tickera_payment_status, value) when is_binary(value),
    do: Ash.Query.filter(query, tickera_payment_status == ^value)

  defp filter_eq(query, _attr, _value), do: query

  defp filter_last_seen_from(query, value) when value in [nil, ""], do: query

  defp filter_last_seen_from(query, %DateTime{} = value),
    do: Ash.Query.filter(query, last_seen_at >= ^value)

  defp filter_last_seen_from(query, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> filter_last_seen_from(query, datetime)
      _ -> Ash.Query.filter(query, false)
    end
  end

  defp filter_last_seen_to(query, value) when value in [nil, ""], do: query

  defp filter_last_seen_to(query, %DateTime{} = value),
    do: Ash.Query.filter(query, last_seen_at <= ^value)

  defp filter_last_seen_to(query, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> filter_last_seen_to(query, datetime)
      _ -> Ash.Query.filter(query, false)
    end
  end

  def upsert_open(attrs, opts \\ []) do
    with :ok <- authorize_internal(opts) do
      attrs =
        attrs
        |> Map.new()
        |> Map.put_new(:source_scope_key, source_scope_key(attrs))

      TickeraReconciliationFinding
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_create(:upsert_open, attrs)
      |> Ash.create(domain: Ingestion)
    end
  end

  def resolve(%TickeraReconciliationFinding{} = finding, attrs, opts \\ []) do
    update_authorized(finding, attrs, :resolve, opts)
  end

  def ignore(%TickeraReconciliationFinding{} = finding, attrs, opts \\ []) do
    update_authorized(finding, attrs, :ignore, opts)
  end

  def reopen(%TickeraReconciliationFinding{} = finding, opts \\ []) do
    update_authorized(finding, %{}, :reopen, opts)
  end

  def source_scope_key(attrs) do
    attrs = Map.new(attrs)
    event_id = Map.get(attrs, :event_id) || Map.get(attrs, "event_id")

    source_id =
      Map.get(attrs, :tickera_event_source_id) || Map.get(attrs, "tickera_event_source_id")

    case source_id do
      nil -> "no_source:" <> to_string(event_id)
      source_id -> "source:" <> to_string(source_id)
    end
  end

  def fingerprint(parts) do
    parts
    |> Enum.map_join("|", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp update_authorized(finding, attrs, action, opts) do
    with :ok <- authorize_internal_or_admin(opts) do
      finding
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_update(action, attrs)
      |> Ash.update(domain: Ingestion)
    end
  end

  defp authorize_read(opts), do: authorize_internal_or_admin(opts)

  defp authorize_internal(opts) do
    if Keyword.get(opts, :internal?) == true do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_internal_or_admin(opts) do
    cond do
      Keyword.get(opts, :internal?) == true -> :ok
      opts |> Keyword.get(:actor) |> Policies.global_admin?() -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> normalize_limit()
    |> min(@max_limit)
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit
end
