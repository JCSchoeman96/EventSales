defmodule Mix.Tasks.Eventsales.Catalog.DryRunTest do
  use EventSales.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncFinding
  alias EventSales.TestSupport.CatalogSyncRunHelpers

  setup do
    original_feed = Application.get_env(:event_sales, :tickera_catalog_feed)
    original_auto_apply = Application.get_env(:event_sales, :catalog_auto_apply)
    original_env = Application.get_env(:event_sales, :env)
    original_repo = Application.get_env(:event_sales, EventSales.Repo)
    original_log_level = Logger.level()

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(:event_sales, :tickera_catalog_feed,
      base_url: "http://localhost:10059",
      secret: "test-only-secret"
    )

    Application.put_env(:event_sales, :catalog_auto_apply, hard_enabled: false)
    System.delete_env("CATALOG_AUTO_APPLY_HARD_ENABLED")

    on_exit(fn ->
      restore_env(:tickera_catalog_feed, original_feed)
      restore_env(:catalog_auto_apply, original_auto_apply)
      restore_env(:env, original_env)
      restore_env(EventSales.Repo, original_repo)
      Logger.configure(level: original_log_level)
      Mix.Task.reenable("eventsales.catalog.dry_run")
    end)

    :ok
  end

  test "reports reused run, severity counts, and sorted codes without finding metadata" do
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

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{
          dry_run_hash: "task-ready-hash",
          summary: %{"finding_count" => 3},
          plan_snapshot: %{
            "ticket_type_changes" => [
              %{"external_variation_id" => 400_741},
              %{"external_variation_id" => 400_742}
            ]
          }
        }
      )

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
          message: "Safe task finding",
          metadata: %{"must_not_appear" => "private-source-payload"}
        },
        action: :create,
        domain: Ingestion
      )
    end

    output =
      capture_io(fn ->
        Mix.Tasks.Eventsales.Catalog.DryRun.run([
          "--source-system-id",
          source.id,
          "--expected-variation-ids",
          "400741,400742"
        ])
      end)

    assert output =~ "Run ID: #{run.id}"
    assert output =~ "Run source: reused"
    assert output =~ "Status: dry_run_ready"
    assert output =~ "Findings: 3"
    assert output =~ "Blocking: 1"
    assert output =~ "Warnings: 1"
    assert output =~ "Info: 1"

    assert output =~
             "Finding codes:\n- existing_mapping_adopted\n- malformed_identity\n- source_metadata_changed"

    refute output =~ "must_not_appear"
    refute output =~ "private-source-payload"
  end

  test "reserved local operator creation never logs credential or SQL material" do
    source = create_local_source!()
    run = create_ready_run!(source.id)
    parent = self()

    output =
      capture_io(fn ->
        log =
          capture_log(fn ->
            Mix.Tasks.Eventsales.Catalog.DryRun.run([
              "--source-system-id",
              source.id,
              "--expected-variation-ids",
              "400741,400742"
            ])
          end)

        send(parent, {:captured_log, log})
      end)

    assert_receive {:captured_log, log}
    combined = output <> log

    assert output =~ "Run ID: #{run.id}"
    assert output =~ "Run source: reused"
    assert output =~ "Status: dry_run_ready"

    repo_config = Application.fetch_env!(:event_sales, EventSales.Repo)
    assert repo_config[:log] == false
    assert repo_config[:show_sensitive_data_on_connection_error] == false

    for forbidden <- [
          "hashed_password",
          "INSERT INTO \"accounts_users\"",
          "accounts_users",
          "password_confirmation",
          "$2a$",
          "$2b$",
          "$2y$",
          "$argon2",
          "$pbkdf2"
        ] do
      refute combined =~ forbidden
    end
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
      %{
        dry_run_hash: "task-operator-ready-hash",
        summary: %{"finding_count" => 0},
        plan_snapshot: %{
          "ticket_type_changes" => [
            %{"external_variation_id" => 400_741},
            %{"external_variation_id" => 400_742}
          ]
        }
      }
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
