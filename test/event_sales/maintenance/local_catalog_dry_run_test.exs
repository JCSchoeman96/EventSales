defmodule EventSales.Maintenance.LocalCatalogDryRunTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Catalog.TickeraCatalog.DiscoveryResult
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.Maintenance.LocalCatalogDryRun
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, TickeraCatalogFixtures}

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
    operator = create_admin!()

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
             Oban.Testing.with_testing_mode(:inline, fn ->
               LocalCatalogDryRun.run(
                 operator: operator,
                 source_system_id: source.id,
                 expected_variation_ids: [400_741, 400_742],
                 fresh?: true
               )
             end)

    assert result.status == :dry_run_ready
    assert result.fresh_requested
    assert result.superseded_run_id == nil
    refute result.reused_existing_run
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

  test "reuses a ready run with persisted finding summary and no new job" do
    operator = create_admin!()
    source = create_local_source!()
    run = create_ready_run!(source.id)

    for {severity, code} <- [
          {:warning, "source_metadata_changed"},
          {:blocking, "malformed_identity"},
          {:info, "existing_mapping_adopted"}
        ] do
      Ash.create!(
        TickeraCatalogSyncFinding,
        %{
          run_id: run.id,
          severity: severity,
          code: code,
          message: "Safe test finding",
          metadata: %{"must_not_appear" => "private"}
        },
        action: :create,
        domain: Ingestion
      )
    end

    run_count = run_count()
    job_count = discovery_job_count()

    assert {:ok, result} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               expected_variation_ids: [400_741, 400_742]
             )

    assert result.run_id == run.id
    refute result.fresh_requested
    assert result.superseded_run_id == nil
    assert result.reused_existing_run
    assert result.finding_summary == %{blocking: 1, warning: 1, info: 1, total: 3}

    assert result.finding_codes == [
             "existing_mapping_adopted",
             "malformed_identity",
             "source_metadata_changed"
           ]

    refute Map.has_key?(result, :finding_metadata)
    assert run_count() == run_count
    assert discovery_job_count() == job_count
  end

  for status <- [:queued, :discovering, :retry_scheduled] do
    test "reuses and polls an existing #{status} run" do
      status = unquote(status)
      operator = create_admin!()
      source = create_local_source!()
      run = create_run_in_status!(source.id, status)
      run_count = run_count()
      job_count = discovery_job_count()

      poll_run = fn run_id ->
        assert run_id == run.id
        {:ok, transition_to_ready!(Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion))}
      end

      assert {:ok, result} =
               LocalCatalogDryRun.run(
                 operator: operator,
                 source_system_id: source.id,
                 expected_variation_ids: [400_741, 400_742],
                 poll_run: poll_run
               )

      assert result.run_id == run.id
      assert result.reused_existing_run
      assert run_count() == run_count
      assert discovery_job_count() == job_count
    end

    test "fresh mode reuses and polls an existing #{status} run" do
      status = unquote(status)
      operator = create_admin!()
      source = create_local_source!()
      run = create_run_in_status!(source.id, status)
      run_count = run_count()

      poll_run = fn _run_id ->
        {:ok, transition_to_ready!(Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion))}
      end

      assert {:ok, result} =
               LocalCatalogDryRun.run(
                 operator: operator,
                 source_system_id: source.id,
                 expected_variation_ids: [400_741, 400_742],
                 fresh?: true,
                 poll_run: poll_run
               )

      assert result.run_id == run.id
      assert result.fresh_requested
      assert result.superseded_run_id == nil
      assert result.reused_existing_run
      assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :dry_run_ready
      assert run_count() == run_count
    end
  end

  test "fresh mode supersedes a ready run, preserves its audit, and creates a new run" do
    operator = create_admin!()
    source = create_local_source!()
    old_run = create_ready_run!(source.id)

    finding =
      Ash.create!(
        TickeraCatalogSyncFinding,
        %{
          run_id: old_run.id,
          severity: :warning,
          code: "preserved_finding",
          message: "Preserve this finding"
        },
        action: :create,
        domain: Ingestion
      )

    before_counts = catalogue_counts()

    assert {:ok, result} =
             Oban.Testing.with_testing_mode(:inline, fn ->
               LocalCatalogDryRun.run(
                 operator: operator,
                 source_system_id: source.id,
                 expected_variation_ids: [400_741, 400_742],
                 fresh?: true
               )
             end)

    assert result.fresh_requested
    assert result.superseded_run_id == old_run.id
    refute result.reused_existing_run
    refute result.run_id == old_run.id

    superseded = Ash.get!(TickeraCatalogSyncRun, old_run.id, domain: Ingestion)
    assert superseded.status == :cancelled
    assert superseded.cancelled_by_user_id == operator.id
    assert superseded.cancellation_reason_code == :superseded
    assert superseded.cancellation_reason_details == "Explicit local catalogue refresh"
    assert superseded.requested_by_user_id == old_run.requested_by_user_id
    assert superseded.dry_run_hash == old_run.dry_run_hash
    assert superseded.plan_snapshot == old_run.plan_snapshot
    assert Ash.get!(TickeraCatalogSyncFinding, finding.id, domain: Ingestion).run_id == old_run.id

    new_run = Ash.get!(TickeraCatalogSyncRun, result.run_id, domain: Ingestion)
    assert new_run.source_system_id == old_run.source_system_id
    assert new_run.scope == %{"kind" => "wordpress_feed", "mode" => "full"}
    assert new_run.status == :dry_run_ready
    assert catalogue_counts() == before_counts
    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  test "returns apply_in_progress without mutating an applying run" do
    operator = create_admin!()
    source = create_local_source!()
    applying = source.id |> create_ready_run!() |> CatalogSyncRunHelpers.claim_applying!()
    run_count = run_count()
    job_count = discovery_job_count()

    assert {:error, :apply_in_progress} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               fresh?: true
             )

    assert Ash.get!(TickeraCatalogSyncRun, applying.id, domain: Ingestion).status == :applying
    assert run_count() == run_count
    assert discovery_job_count() == job_count
  end

  test "rejects an unexpected applied run returned by the active-run reader" do
    operator = create_admin!()
    source = create_local_source!()

    active_run_for_source = fn _source_id, _operator ->
      {:ok, %{id: Ash.UUID.generate(), status: :applied}}
    end

    assert {:error, :unexpected_apply_state} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               active_run_for_source: active_run_for_source
             )

    assert run_count() == 0
    assert discovery_job_count() == 0
  end

  test "recovers one queue race by reloading and reusing the active run" do
    operator = create_admin!()
    source = create_local_source!()
    ready = create_ready_run!(source.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    active_run_for_source = fn _source_id, _operator ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})
      if call == 0, do: {:ok, nil}, else: {:ok, ready}
    end

    queue_dry_run = fn _source_id, _operator -> {:error, :catalog_sync_already_active} end

    assert {:ok, result} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               expected_variation_ids: [400_741, 400_742],
               active_run_for_source: active_run_for_source,
               queue_dry_run: queue_dry_run
             )

    assert result.run_id == ready.id
    assert result.reused_existing_run
    assert Agent.get(calls, & &1) == 2
  end

  test "fresh revocation race reloads once and reuses the winner's run" do
    operator = create_admin!()
    source = create_local_source!()
    old_run = create_ready_run!(source.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    revoke_ready_run = fn run_id, actor ->
      assert run_id == old_run.id

      assert {:ok, _cancelled} =
               EventSales.Ingestion.TickeraCatalogSync.revoke_ready_dry_run(
                 run_id,
                 %{
                   cancellation_reason_code: :superseded,
                   cancellation_reason_details: "Concurrent refresh"
                 },
                 actor: actor
               )

      create_ready_run!(source.id)
      {:error, :already_cancelled}
    end

    active_run_for_source = fn _source_id, _operator ->
      Agent.update(calls, &(&1 + 1))
      EventSales.Ingestion.TickeraCatalogSync.active_run_for_source(source.id, actor: operator)
    end

    assert {:ok, result} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               expected_variation_ids: [400_741, 400_742],
               fresh?: true,
               active_run_for_source: active_run_for_source,
               revoke_ready_run: revoke_ready_run
             )

    assert result.superseded_run_id == old_run.id
    assert result.reused_existing_run
    refute result.run_id == old_run.id
    assert Agent.get(calls, & &1) == 2
  end

  test "fresh queue race reloads once and reuses the winning run" do
    operator = create_admin!()
    source = create_local_source!()
    old_run = create_ready_run!(source.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    queue_dry_run = fn source_id, _operator ->
      create_ready_run!(source_id)
      {:error, :catalog_sync_already_active}
    end

    active_run_for_source = fn _source_id, _operator ->
      Agent.update(calls, &(&1 + 1))
      EventSales.Ingestion.TickeraCatalogSync.active_run_for_source(source.id, actor: operator)
    end

    assert {:ok, result} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               expected_variation_ids: [400_741, 400_742],
               fresh?: true,
               active_run_for_source: active_run_for_source,
               queue_dry_run: queue_dry_run
             )

    assert result.superseded_run_id == old_run.id
    assert result.reused_existing_run
    refute result.run_id == old_run.id
    assert Agent.get(calls, & &1) == 2
  end

  test "fresh mode changes only the requested source" do
    operator = create_admin!()
    source_a = create_local_source!()

    source_b =
      Ash.create!(
        SourceSystem,
        %{
          name: "Other local source",
          kind: :woocommerce,
          base_url: "http://other.localhost:10059",
          active: true,
          catalog_auto_apply_mode: :disabled,
          catalog_auto_apply_allowlisted: false
        },
        action: :create,
        domain: Catalog
      )

    run_a = create_ready_run!(source_a.id)
    run_b = create_ready_run!(source_b.id)

    assert {:ok, result} =
             Oban.Testing.with_testing_mode(:inline, fn ->
               LocalCatalogDryRun.run(
                 operator: operator,
                 source_system_id: source_a.id,
                 expected_variation_ids: [400_741, 400_742],
                 fresh?: true
               )
             end)

    assert result.superseded_run_id == run_a.id
    assert Ash.get!(TickeraCatalogSyncRun, run_a.id, domain: Ingestion).status == :cancelled
    assert Ash.get!(TickeraCatalogSyncRun, run_b.id, domain: Ingestion).status == :dry_run_ready
  end

  test "fresh mode rejects a non-admin before revoking a ready run" do
    operator = create_user!()
    source = create_local_source!()
    ready = create_ready_run!(source.id)
    job_count = discovery_job_count()

    assert {:error, :local_operator_not_authorized} =
             LocalCatalogDryRun.run(
               operator: operator,
               source_system_id: source.id,
               fresh?: true
             )

    assert Ash.get!(TickeraCatalogSyncRun, ready.id, domain: Ingestion).status == :dry_run_ready
    assert discovery_job_count() == job_count
  end

  defp catalogue_counts do
    %{
      events: Event |> Ash.read!(domain: Catalog) |> length(),
      ticket_types: TicketType |> Ash.read!(domain: Catalog) |> length(),
      product_mappings: ProductMapping |> Ash.read!(domain: Catalog) |> length()
    }
  end

  defp create_local_source! do
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
  end

  defp create_ready_run!(source_system_id) do
    CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
      source_system_id,
      %{"kind" => "wordpress_feed", "mode" => "full"},
      ready_attrs()
    )
  end

  defp create_run_in_status!(source_system_id, :queued),
    do:
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
        source_system_id,
        %{"kind" => "wordpress_feed", "mode" => "full"}
      )

  defp create_run_in_status!(source_system_id, :discovering),
    do:
      CatalogSyncRunHelpers.create_discovering_catalog_sync_run!(
        source_system_id,
        %{"kind" => "wordpress_feed", "mode" => "full"}
      )

  defp create_run_in_status!(source_system_id, :retry_scheduled) do
    CatalogSyncRunHelpers.create_retry_scheduled_catalog_sync_run!(
      source_system_id,
      %{"kind" => "wordpress_feed", "mode" => "full"},
      %{last_error: "catalog_feed_timeout", retry_attempt: 1, retry_max_attempts: 3}
    )
  end

  defp transition_to_ready!(%{status: :queued} = run),
    do: run |> CatalogSyncRunHelpers.mark_discovering!() |> transition_to_ready!()

  defp transition_to_ready!(%{status: :retry_scheduled} = run),
    do: run |> CatalogSyncRunHelpers.mark_discovering!() |> transition_to_ready!()

  defp transition_to_ready!(%{status: :discovering} = run),
    do: CatalogSyncRunHelpers.mark_ready!(run, ready_attrs())

  defp ready_attrs do
    snapshot = %{
      "dry_run_hash" => "local-ready-hash",
      "event_changes" => [],
      "ticket_type_changes" => [
        %{"external_variation_id" => 400_741},
        %{"external_variation_id" => 400_742}
      ],
      "product_mapping_changes" => [
        %{"woo_variation_id" => 400_741},
        %{"woo_variation_id" => 400_742}
      ],
      "findings" => [],
      "touched_event_ids" => [],
      "touched_product_keys" => [[400_740, 400_741], [400_740, 400_742]]
    }

    %{
      dry_run_hash: "local-ready-hash",
      summary: %{"finding_count" => 0},
      plan_snapshot: snapshot
    }
  end

  defp create_admin! do
    user = create_user!()

    role =
      Role
      |> Ash.Query.filter(name == :admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end

  defp create_user! do
    password = "Local-test-password-123!"

    Ash.create!(
      User,
      %{
        email: "local-dry-run-#{System.unique_integer([:positive])}@example.com",
        name: "Local Dry Run",
        password: password,
        password_confirmation: password
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp run_count, do: TickeraCatalogSyncRun |> Ash.read!(domain: Ingestion) |> length()

  defp discovery_job_count do
    Repo.aggregate(
      from(job in Oban.Job,
        where: job.worker == "EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker"
      ),
      :count
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
