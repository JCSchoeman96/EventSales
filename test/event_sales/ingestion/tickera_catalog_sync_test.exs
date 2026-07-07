defmodule EventSales.Ingestion.TickeraCatalogSyncTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}
  alias EventSales.TestSupport.{SalesHelpers, TickeraCatalogFixtures}

  setup do
    admin = create_user!("tickera-catalog-admin@example.com")
    staff = create_user!("tickera-catalog-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    source = SalesHelpers.create_source_system!()

    {:ok, admin: admin, staff: staff, source: source}
  end

  test "queue_dry_run authorizes admins and enqueues discover worker", %{
    admin: admin,
    staff: staff,
    source: source
  } do
    scope = manual_scope()

    assert {:error, :forbidden} =
             TickeraCatalogSync.queue_dry_run(%{source_system_id: source.id, scope: scope},
               actor: staff
             )

    assert {:ok, %{run: run, job: job}} =
             TickeraCatalogSync.queue_dry_run(%{source_system_id: source.id, scope: scope},
               actor: admin
             )

    assert run.status == :queued
    assert job.queue == "tickera_sync"

    assert_enqueued(
      worker: DiscoverTickeraCatalogWorker,
      queue: :tickera_sync,
      args: %{"run_id" => run.id}
    )
  end

  test "list_runs and get_run_preview are admin-only", %{
    admin: admin,
    staff: staff,
    source: source
  } do
    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{"kind" => "manual_rows"}},
        action: :create_dry_run,
        domain: Ingestion
      )

    assert {:error, :forbidden} = TickeraCatalogSync.list_runs(actor: staff)
    assert {:ok, [_run]} = TickeraCatalogSync.list_runs(actor: admin)
    assert {:error, :forbidden} = TickeraCatalogSync.get_run_preview(run.id, actor: staff)
    assert {:ok, %{run: loaded_run}} = TickeraCatalogSync.get_run_preview(run.id, actor: admin)
    assert loaded_run.id == run.id
  end

  test "queue_apply rejects blocking findings before enqueue", %{admin: admin, source: source} do
    run =
      create_dry_run!(source.id, %{
        "dry_run_hash" => "blocked-hash",
        "event_changes" => [],
        "ticket_type_changes" => [],
        "product_mapping_changes" => [],
        "findings" => [
          %{
            "severity" => "blocking",
            "code" => "ambiguous_variation_ticket_type_name",
            "message" =>
              "Published product variation could not produce a distinct TicketType name."
          }
        ],
        "touched_event_ids" => [],
        "touched_product_keys" => []
      })

    assert {:error, :blocking_findings} =
             TickeraCatalogSync.queue_apply(run.id, "blocked-hash", actor: admin)

    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  test "queue_apply rejects missing previews before enqueue", %{admin: admin, source: source} do
    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{"kind" => "wordpress_feed", "mode" => "full"},
          status: :dry_run_ready,
          dry_run_hash: "missing-preview-hash",
          summary: %{"finding_count" => 4},
          plan_snapshot: nil
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    assert {:error, :missing_plan_snapshot} =
             TickeraCatalogSync.queue_apply(run.id, "missing-preview-hash", actor: admin)

    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  defp manual_scope do
    %{
      "kind" => "manual_rows",
      "events" => [TickeraCatalogFixtures.zero_product_event()],
      "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
    }
  end

  defp create_dry_run!(source_system_id, snapshot) do
    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source_system_id,
        scope: %{"kind" => "wordpress_feed", "mode" => "full"},
        status: :dry_run_ready,
        dry_run_hash: snapshot["dry_run_hash"],
        summary: %{"finding_count" => length(snapshot["findings"])},
        plan_snapshot: snapshot
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end
end
