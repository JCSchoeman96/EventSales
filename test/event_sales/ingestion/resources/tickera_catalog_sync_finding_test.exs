defmodule EventSales.Ingestion.Resources.TickeraCatalogSyncFindingTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncFinding
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers}

  test "reloads a cold persisted finding code as a string without creating an atom" do
    source = SalesHelpers.create_source_system!()
    run = CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)

    code =
      ["cold", "persisted", "finding", Integer.to_string(System.unique_integer([:positive]))]
      |> Enum.join("_")

    finding =
      Ash.create!(
        TickeraCatalogSyncFinding,
        %{
          run_id: run.id,
          severity: :warning,
          code: code,
          message: "Cold persisted code",
          metadata: %{}
        },
        action: :create,
        domain: Ingestion
      )

    reloaded = Ash.get!(TickeraCatalogSyncFinding, finding.id, domain: Ingestion)

    assert reloaded.code == code
    assert is_binary(reloaded.code)
  end

  test "stores qualified source_risk.v3 finding codes without creating atoms" do
    source = SalesHelpers.create_source_system!()
    run = CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)

    codes = ["source_risk.lifecycle_draft", "contract.evidence_conflict"]

    for code <- codes do
      finding =
        Ash.create!(
          TickeraCatalogSyncFinding,
          %{
            run_id: run.id,
            severity: :blocking,
            code: code,
            message: "Native source-risk finding: #{code} (explicit_risk)",
            metadata: %{"disposition" => "explicit_risk", "dimension_local_only" => true}
          },
          action: :create,
          domain: Ingestion
        )

      reloaded = Ash.get!(TickeraCatalogSyncFinding, finding.id, domain: Ingestion)

      assert reloaded.code == code
      assert is_binary(reloaded.code)
      assert byte_size(reloaded.code) <= 120
      assert reloaded.severity == :blocking
      assert reloaded.metadata["disposition"] == "explicit_risk"
      assert_raise ArgumentError, fn -> String.to_existing_atom(code) end
    end
  end

  test "reloads the locally observed variation mapping code as a string" do
    source = SalesHelpers.create_source_system!()
    run = CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)
    code = "variation_mapping_required"

    finding =
      Ash.create!(
        TickeraCatalogSyncFinding,
        %{
          run_id: run.id,
          severity: :warning,
          code: code,
          message: "Variation mapping required",
          metadata: %{}
        },
        action: :create,
        domain: Ingestion
      )

    reloaded = Ash.get!(TickeraCatalogSyncFinding, finding.id, domain: Ingestion)

    assert reloaded.code == code
    assert is_binary(reloaded.code)
  end
end
