defmodule EventSales.Maintenance.LocalCatalogDryRunTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Catalog.TickeraCatalog.DiscoveryResult
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.Maintenance.LocalCatalogDryRun
  alias EventSales.TestSupport.TickeraCatalogFixtures

  defmodule FixtureDiscoverySource do
    @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

    @impl true
    def discover(_source_system_id, %{"kind" => "wordpress_feed", "mode" => "full"}) do
      rows = TickeraCatalogFixtures.variation_rows()
      variation_event = rows |> hd() |> Map.take(Map.keys(TickeraCatalogFixtures.vwg_event()))

      {:ok,
       %DiscoveryResult{
         schema_version: "2026-07-08.v1",
         events: [variation_event, TickeraCatalogFixtures.zero_product_event()],
         catalog_rows: rows,
         source_snapshot_at: ~U[2026-07-28 10:00:00Z]
       }}
    end
  end

  setup do
    original_source = Application.get_env(:event_sales, :tickera_catalog_discovery_source)
    original_feed = Application.get_env(:event_sales, :tickera_catalog_feed)
    original_auto_apply = Application.get_env(:event_sales, :catalog_auto_apply)
    original_env = Application.get_env(:event_sales, :env)

    Application.put_env(
      :event_sales,
      :tickera_catalog_discovery_source,
      FixtureDiscoverySource
    )

    Application.put_env(:event_sales, :tickera_catalog_feed,
      base_url: "http://localhost:10059",
      secret: "test-only-secret"
    )

    Application.put_env(:event_sales, :catalog_auto_apply, hard_enabled: false)

    on_exit(fn ->
      restore_env(:tickera_catalog_discovery_source, original_source)
      restore_env(:tickera_catalog_feed, original_feed)
      restore_env(:catalog_auto_apply, original_auto_apply)
      restore_env(:env, original_env)
    end)

    :ok
  end

  test "persists a full-feed dry run with exact variations and never applies catalogue changes" do
    source =
      Ash.create!(
        SourceSystem,
        %{
          name: "Local WordPress",
          kind: :woocommerce,
          base_url: "http://localhost:10059",
          active: true,
          catalog_auto_apply_mode: :disabled,
          catalog_auto_apply_allowlisted: false
        },
        action: :create,
        domain: Catalog
      )

    before_counts = catalogue_counts()

    assert {:ok, result} =
             LocalCatalogDryRun.run(
               source_system_id: source.id,
               expected_variation_ids: [400_741, 400_742]
             )

    assert result.status == :dry_run_ready
    assert result.expected_variation_ids_present?
    assert result.variation_ids == [400_741, 400_742]
    assert result.finding_count > 0
    assert catalogue_counts() == before_counts

    run = Ash.get!(TickeraCatalogSyncRun, result.run_id, domain: Ingestion)
    findings = Ash.read!(TickeraCatalogSyncFinding, domain: Ingestion)

    assert run.status == :dry_run_ready
    assert run.scope == %{"kind" => "wordpress_feed", "mode" => "full"}
    assert run.plan_snapshot
    assert Enum.any?(findings, &(&1.run_id == run.id))
    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  test "rejects non-local feed configuration before creating a run" do
    Application.put_env(:event_sales, :tickera_catalog_feed,
      base_url: "https://wordpress.example.test",
      secret: "test-only-secret"
    )

    assert {:error, :non_local_catalog_feed} = LocalCatalogDryRun.run()
    assert Ash.read!(TickeraCatalogSyncRun, domain: Ingestion) == []
  end

  test "rejects non-development runtime environments before creating a run" do
    Application.put_env(:event_sales, :env, :prod)

    assert {:error, :not_local_runtime} = LocalCatalogDryRun.run()
    assert Ash.read!(TickeraCatalogSyncRun, domain: Ingestion) == []
  end

  test "rejects enabled catalogue auto-Apply before creating a run" do
    Application.put_env(:event_sales, :catalog_auto_apply, hard_enabled: true)

    assert {:error, :catalog_auto_apply_enabled} = LocalCatalogDryRun.run()
    assert Ash.read!(TickeraCatalogSyncRun, domain: Ingestion) == []
  end

  defp catalogue_counts do
    %{
      events: Event |> Ash.read!(domain: Catalog) |> length(),
      ticket_types: TicketType |> Ash.read!(domain: Catalog) |> length(),
      product_mappings: ProductMapping |> Ash.read!(domain: Catalog) |> length()
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
