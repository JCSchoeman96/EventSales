defmodule EventSales.TestSupport.CatalogSyncRunHelpers do
  @moduledoc false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun

  def create_queued_catalog_sync_run!(source_system_id, scope \\ %{"kind" => "manual_rows"}) do
    Ash.create!(TickeraCatalogSyncRun, %{source_system_id: source_system_id, scope: scope},
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  def create_discovering_catalog_sync_run!(source_system_id, scope \\ %{"kind" => "manual_rows"}) do
    source_system_id |> create_queued_catalog_sync_run!(scope) |> mark_discovering!()
  end

  def mark_discovering!(run),
    do: Ash.update!(run, %{}, action: :mark_discovering, domain: Ingestion)

  def mark_retry_scheduled!(run, attrs) do
    Ash.update!(run, attrs, action: :mark_retry_scheduled, domain: Ingestion)
  end

  def mark_ready!(run, attrs) do
    Ash.update!(run, attrs, action: :mark_dry_run_ready, domain: Ingestion)
  end

  def mark_failed!(run, attrs \\ %{}) do
    Ash.update!(run, attrs, action: :mark_failed, domain: Ingestion)
  end

  def claim_applying!(run), do: Ash.update!(run, %{}, action: :claim_for_apply, domain: Ingestion)
  def mark_applied!(run), do: Ash.update!(run, %{}, action: :mark_applied, domain: Ingestion)

  def create_retry_scheduled_catalog_sync_run!(source_system_id, scope, retry_attrs) do
    source_system_id
    |> create_discovering_catalog_sync_run!(scope)
    |> mark_retry_scheduled!(retry_attrs)
  end

  def create_ready_catalog_sync_run!(source_system_id, scope, ready_attrs) do
    source_system_id |> create_discovering_catalog_sync_run!(scope) |> mark_ready!(ready_attrs)
  end

  def create_failed_catalog_sync_run!(source_system_id, scope, attrs \\ %{}) do
    source_system_id |> create_discovering_catalog_sync_run!(scope) |> mark_failed!(attrs)
  end

  def create_applied_catalog_sync_run!(source_system_id, scope, ready_attrs) do
    source_system_id
    |> create_ready_catalog_sync_run!(scope, ready_attrs)
    |> claim_applying!()
    |> mark_applied!()
  end
end
