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
