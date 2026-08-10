defmodule EventSales.Ingestion.TickeraCatalogEventProductDiscoveryTest do
  @moduledoc """
  Path 1 M2-03 certification: exact local Event → authoritative Woo parent-product membership.
  """

  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.TickeraCatalog.{CatalogRow, DiscoveryResult, Normalizer, Planner}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncFinding
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers, TickeraCatalogFixtures}

  setup do
    admin = create_user!("m2-03-admin@example.com")
    staff = create_user!("m2-03-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    source = SalesHelpers.create_source_system!()

    {:ok, admin: admin, staff: staff, source: source}
  end

  test "exact local Event queues exact event-scoped discovery for its SourceSystem", %{
    admin: admin,
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        name: "M2-03 Concert",
        slug: "m2-03-concert",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    assert {:ok, %{run: run, job: job, event: loaded}} =
             TickeraCatalogSync.queue_event_product_discovery(event.id, actor: admin)

    assert loaded.id == event.id
    assert run.source_system_id == source.id
    assert run.scope == %{"kind" => "wordpress_feed", "event_id" => 123}
    assert run.status == :queued
    assert job.queue == "tickera_sync"

    assert_enqueued(
      worker: DiscoverTickeraCatalogWorker,
      queue: :tickera_sync,
      args: %{"run_id" => run.id}
    )
  end

  test "cross-source isolation keeps discovery bound to the Event SourceSystem", %{
    admin: admin
  } do
    source_a = SalesHelpers.create_source_system!(%{base_url: "https://m2-03-a.example.test"})
    source_b = SalesHelpers.create_source_system!(%{base_url: "https://m2-03-b.example.test"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Source A Event 123",
        slug: "source-a-event-123",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Source B Event 123",
        slug: "source-b-event-123",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    assert {:ok, %{run: run_a}} =
             TickeraCatalogSync.queue_event_product_discovery(event_a.id, actor: admin)

    assert {:ok, %{run: run_b}} =
             TickeraCatalogSync.queue_event_product_discovery(event_b.id, actor: admin)

    assert run_a.source_system_id == source_a.id
    assert run_b.source_system_id == source_b.id
    assert run_a.scope == %{"kind" => "wordpress_feed", "event_id" => 123}
    assert run_b.scope == %{"kind" => "wordpress_feed", "event_id" => 123}
    refute run_a.source_system_id == run_b.source_system_id
  end

  test "staff cannot queue event-product discovery", %{staff: staff, source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Forbidden Event",
        slug: "forbidden-event",
        external_event_kind: :tickera_event,
        external_event_id: 456
      })

    assert {:error, :forbidden} =
             TickeraCatalogSync.queue_event_product_discovery(event.id, actor: staff)

    refute_enqueued(worker: DiscoverTickeraCatalogWorker)
  end

  test "missing authoritative Tickera identity fails closed without discovery job", %{
    admin: admin,
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        name: "No External ID",
        slug: "no-external-id"
      })

    run_count = catalog_sync_run_count()
    job_count = discovery_job_count()

    assert {:error, :missing_external_event_identity} =
             TickeraCatalogSync.queue_event_product_discovery(event.id, actor: admin)

    assert catalog_sync_run_count() == run_count
    assert discovery_job_count() == job_count
    refute_enqueued(worker: DiscoverTickeraCatalogWorker)
  end

  test "unknown local Event fails closed without discovery job", %{admin: admin} do
    run_count = catalog_sync_run_count()
    job_count = discovery_job_count()

    assert {:error, :event_not_found} =
             TickeraCatalogSync.queue_event_product_discovery(Ecto.UUID.generate(), actor: admin)

    assert catalog_sync_run_count() == run_count
    assert discovery_job_count() == job_count
  end

  test "projects exact parent product membership for the selected Event", %{source: source} do
    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: nil},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 600, woo_variation_id: nil}
    ]

    assert {:ok, %{products: products, product_count: 2}} =
             TickeraCatalogSync.project_event_parent_products(source.id, 123, rows)

    assert products == [
             %{source_system_id: source.id, woo_product_id: 500},
             %{source_system_id: source.id, woo_product_id: 600}
           ]
  end

  test "variation rows collapse to one parent product for M2-03", %{source: source} do
    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 501},
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: 502}
    ]

    assert {:ok, %{products: products, product_count: 1}} =
             TickeraCatalogSync.project_event_parent_products(source.id, 123, rows)

    assert products == [%{source_system_id: source.id, woo_product_id: 500}]
  end

  test "foreign Event row fails closed and is not certified", %{source: source} do
    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: 500, woo_variation_id: nil},
      %CatalogRow{tickera_event_id: 999, woo_product_id: 700, woo_variation_id: nil}
    ]

    assert {:error, :foreign_event_row} =
             TickeraCatalogSync.project_event_parent_products(source.id, 123, rows)
  end

  test "invalid product identity fails closed", %{source: source} do
    rows = [
      %CatalogRow{tickera_event_id: 123, woo_product_id: nil, woo_variation_id: nil}
    ]

    assert {:error, :invalid_product_identity} =
             TickeraCatalogSync.project_event_parent_products(source.id, 123, rows)
  end

  test "zero eligible products remain explicit without fabricated mappings", %{source: source} do
    assert {:ok, %{products: [], product_count: 0}} =
             TickeraCatalogSync.project_event_parent_products(source.id, 300_001, [])

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id, %{
        "kind" => "manual_rows",
        "events" => [TickeraCatalogFixtures.zero_product_event()],
        "catalog_rows" => []
      })

    mapping_count_before = Ash.count!(ProductMapping, domain: Catalog)

    assert :ok = DiscoverTickeraCatalogWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

    findings = Ash.read!(TickeraCatalogSyncFinding, domain: Ingestion)
    assert Enum.any?(findings, &(&1.code == "published_event_without_ticket_products"))
    assert Ash.count!(ProductMapping, domain: Catalog) == mapping_count_before

    ready =
      Ash.get!(EventSales.Ingestion.Resources.TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert ready.status == :dry_run_ready
    assert ready.plan_snapshot["product_mapping_changes"] == []
  end

  test "existing conflicting ProductMapping remains a review finding without mutation", %{
    source: source
  } do
    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other Event",
        slug: "other-event-conflict",
        external_event_kind: :tickera_event,
        external_event_id: 108_000
      })

    ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Conflict Ticket"})

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: other_event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 109_740,
          woo_variation_id: nil,
          original_label: "Conflict Ticket",
          current_label: "Conflict Ticket",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    discovery = %DiscoveryResult{
      schema_version: "2026-03-26.v2",
      auto_apply_proof_complete?: false,
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, normalized} = Normalizer.normalize(discovery)

    assert {:ok, membership} =
             TickeraCatalogSync.project_event_parent_products(
               source.id,
               109_316,
               normalized.rows
             )

    assert membership.products == [
             %{source_system_id: source.id, woo_product_id: 109_740}
           ]

    assert {:ok, plan} = Planner.plan(source.id, discovery)

    assert Enum.any?(
             plan.findings,
             &(&1.code == :existing_mapping_conflict and &1.woo_product_id == 109_740)
           )

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert reloaded.active
    assert reloaded.event_id == other_event.id
    assert reloaded.woo_product_id == 109_740
  end

  test "normalized pipeline parent products match M2-03 projection", %{source: source} do
    [row_a, row_b] = TickeraCatalogFixtures.variation_rows()

    simple =
      TickeraCatalogFixtures.vwg_row()
      |> Map.put("tickera_event_id", 400_001)
      |> Map.put("woo_product_id", 400_999)
      |> Map.put("woo_variation_id", nil)

    discovery = %DiscoveryResult{
      schema_version: "2026-03-26.v2",
      auto_apply_proof_complete?: false,
      events: [
        %{
          "tickera_event_id" => 400_001,
          "event_title" => "Variation Event",
          "event_slug" => "variation-event",
          "event_status" => "publish"
        }
      ],
      catalog_rows: [row_a, row_b, simple]
    }

    assert {:ok, %{rows: rows}} = Normalizer.normalize(discovery)

    assert {:ok, %{products: products, product_count: 2}} =
             TickeraCatalogSync.project_event_parent_products(source.id, 400_001, rows)

    assert products == [
             %{source_system_id: source.id, woo_product_id: 400_740},
             %{source_system_id: source.id, woo_product_id: 400_999}
           ]
  end

  defp catalog_sync_run_count do
    EventSales.Ingestion.Resources.TickeraCatalogSyncRun
    |> Ash.Query.new()
    |> Ash.count!(domain: Ingestion)
  end

  defp discovery_job_count do
    Repo.aggregate(Oban.Job, :count, :id)
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
