defmodule EventSales.TestSupport.FinancialReconciliationHelpers do
  @moduledoc false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.TestSupport.HistoricalCoverageHelpers

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]

  def coverage_start, do: @coverage_start
  def sales_covered_through, do: @sales_covered_through
  def refunds_covered_through, do: @refunds_covered_through

  def certified_run!(event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(
      %{
        coverage_start: @coverage_start,
        sales_covered_through: @sales_covered_through,
        refunds_covered_through: @refunds_covered_through,
        coverage_evidence: HistoricalCoverageHelpers.certified_evidence()
      },
      action: :record_coverage_certification,
      domain: Ingestion
    )
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  def scope_map(%SyncRun{} = sync_run) do
    %{
      sync_run_id: sync_run.id,
      event_id: sync_run.event_id,
      source_system_id: sync_run.source_system_id,
      coverage_start: sync_run.coverage_start,
      sales_covered_through: sync_run.sales_covered_through,
      refunds_covered_through: sync_run.refunds_covered_through
    }
  end

  def zero_currency_totals(currency \\ "ZAR") do
    primitives =
      EventSales.Sales.FinancialPrimitives.primitives()
      |> Enum.map(fn primitive -> {primitive, Decimal.new(0)} end)
      |> Map.new()

    %{
      sync_run_id: nil,
      event_id: nil,
      source_system_id: nil,
      coverage_start: @coverage_start,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through,
      currencies: %{currency => primitives}
    }
  end

  def successful_result(sync_run, currency \\ "ZAR", overrides \\ %{}) do
    base =
      zero_currency_totals(currency)
      |> Map.merge(%{
        sync_run_id: sync_run.id,
        event_id: sync_run.event_id,
        source_system_id: sync_run.source_system_id,
        coverage_start: sync_run.coverage_start,
        sales_covered_through: sync_run.sales_covered_through,
        refunds_covered_through: sync_run.refunds_covered_through
      })

    Map.update!(base, :currencies, fn currencies ->
      Map.update!(currencies, currency, fn totals -> Map.merge(totals, overrides) end)
    end)
  end
end
