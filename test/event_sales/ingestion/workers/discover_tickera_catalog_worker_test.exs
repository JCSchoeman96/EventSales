defmodule EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker
  alias EventSales.TestSupport.{SalesHelpers, TickeraCatalogFixtures}

  defmodule FailingDiscoverySource do
    @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

    @impl true
    def discover(_source_system_id, _scope) do
      {:error, Application.fetch_env!(:event_sales, :discover_worker_failure_reason)}
    end
  end

  setup do
    original_adapter = Application.get_env(:event_sales, :tickera_catalog_discovery_source)
    original_reason = Application.get_env(:event_sales, :discover_worker_failure_reason)

    on_exit(fn ->
      restore_env(:tickera_catalog_discovery_source, original_adapter)
      restore_env(:discover_worker_failure_reason, original_reason)
    end)
  end

  test "discovers manual rows, persists plan snapshot/findings, and broadcasts ready" do
    source = SalesHelpers.create_source_system!()

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{
            "kind" => "manual_rows",
            "events" => [TickeraCatalogFixtures.zero_product_event()],
            "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
          }
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    PubSub.subscribe(run.id)

    assert :ok = DiscoverTickeraCatalogWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

    updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    findings = Ash.read!(TickeraCatalogSyncFinding, domain: Ingestion)

    assert updated.status == :dry_run_ready
    assert is_binary(updated.dry_run_hash)
    assert is_map(updated.plan_snapshot)
    assert Enum.any?(findings, &(&1.code == :published_event_without_ticket_products))

    assert_receive {:catalog_sync_started, %{run_id: run_id}}
    assert run_id == run.id
    assert_receive {:catalog_sync_preview_ready, %{run_id: run_id}}
    assert run_id == run.id
  end

  test "stores bounded feed discovery errors" do
    source = SalesHelpers.create_source_system!()

    cases = [
      {:misconfigured, "catalog_feed_misconfigured"},
      {:unauthorized, "catalog_feed_unauthorized"},
      {:forbidden, "catalog_feed_forbidden"},
      {:timeout, "catalog_feed_timeout"},
      {:pagination_limit, "catalog_feed_pagination_limit"},
      {:invalid_feed_response, "invalid_catalog_feed_response"},
      {:invalid_json, "invalid_catalog_feed_response"},
      {:rate_limited, "catalog_feed_rate_limited"},
      {:server_error, "catalog_feed_server_error"},
      {:transport_error, "catalog_feed_transport_error"}
    ]

    for {reason, expected_error} <- cases do
      Application.put_env(:event_sales, :tickera_catalog_discovery_source, FailingDiscoverySource)
      Application.put_env(:event_sales, :discover_worker_failure_reason, reason)

      run =
        Ash.create!(
          TickeraCatalogSyncRun,
          %{
            source_system_id: source.id,
            scope: %{"kind" => "wordpress_feed", "mode" => "full"}
          },
          action: :create_dry_run,
          domain: Ingestion
        )

      result = DiscoverTickeraCatalogWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

      if reason in [:timeout, :rate_limited, :server_error, :transport_error] do
        assert {:error, ^reason} = result
      else
        assert :discard = result
      end

      updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
      assert updated.status == :failed
      assert updated.last_error == expected_error
    end
  end

  test "does not retry deterministic planner failures" do
    refute DiscoverTickeraCatalogWorker.retryable_failure?(:historical_impact_scope_too_large)
    assert DiscoverTickeraCatalogWorker.retryable_failure?(:timeout)
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
