defmodule EventSalesWeb.Live.Admin.CatalogSyncLiveTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}
  alias EventSales.TestSupport.{SalesHelpers, TickeraCatalogFixtures}

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})

    admin = create_user!("catalog-sync-admin@example.com")
    staff = create_user!("catalog-sync-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    source = SalesHelpers.create_source_system!()

    {:ok, admin: admin, staff: staff, source: source}
  end

  test "rejects unauthenticated and non-admin access", %{conn: conn, staff: staff} do
    conn = get(conn, "/admin/catalog-sync")
    assert html_response(conn, 401) =~ "Admin access required"

    conn =
      Phoenix.ConnTest.build_conn()
      |> sign_in_as(staff)
      |> get("/admin/catalog-sync")

    assert html_response(conn, 403) =~ "Admin role required"
  end

  test "admin queues manual-row dry-run through facade", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Catalog Sync"
    assert html =~ "VWG Pretoria pilot"

    payload =
      Jason.encode!(%{
        "events" => [TickeraCatalogFixtures.zero_product_event()],
        "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
      })

    html =
      render_submit(view, "queue_dry_run", %{
        "catalog_sync" => %{
          "source_system_id" => source.id,
          "scope_kind" => "woo_product",
          "manual_rows" => payload
        }
      })

    assert html =~ "Catalog dry-run queued"

    assert_enqueued(
      worker: DiscoverTickeraCatalogWorker,
      queue: :tickera_sync
    )
  end

  test "queue button is disabled until source and valid manual JSON are present", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Paste sanitized manual export JSON"
    assert has_element?(view, ~s(button[disabled]), "Queue dry-run")

    html =
      render_change(view, "update_form", %{
        "catalog_sync" => %{
          "source_system_id" => source.id,
          "scope_kind" => "woo_product",
          "manual_rows" => "{not-json"
        }
      })

    assert html =~ "Invalid JSON"
    assert has_element?(view, ~s(button[disabled]), "Queue dry-run")

    html =
      render_change(view, "update_form", %{
        "catalog_sync" => %{
          "source_system_id" => source.id,
          "scope_kind" => "woo_product",
          "manual_rows" => Jason.encode!(%{"events" => [], "catalog_rows" => []})
        }
      })

    assert html =~ "Valid JSON"
    refute has_element?(view, ~s(button[disabled]), "Queue dry-run")
  end

  test "admin queues WordPress feed dry-runs without manual JSON", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    feed_scopes = [
      {"wordpress_feed_full", %{}, %{"kind" => "wordpress_feed", "mode" => "full"}},
      {"wordpress_feed_product", %{"product_id" => "109740"},
       %{"kind" => "wordpress_feed", "product_id" => 109_740}},
      {"wordpress_feed_variation", %{"variation_id" => "109741"},
       %{"kind" => "wordpress_feed", "variation_id" => 109_741}},
      {"wordpress_feed_event", %{"event_id" => "109316"},
       %{"kind" => "wordpress_feed", "event_id" => 109_316}},
      {"wordpress_feed_updated_since", %{"updated_since" => "2026-07-05T10:00:00Z"},
       %{"kind" => "wordpress_feed", "updated_since" => "2026-07-05T10:00:00Z"}}
    ]

    for {scope_kind, extra_form, expected_scope} <- feed_scopes do
      html =
        render_change(view, "update_form", %{
          "catalog_sync" =>
            Map.merge(
              %{
                "source_system_id" => source.id,
                "scope_kind" => scope_kind,
                "manual_rows" => ""
              },
              extra_form
            )
        })

      refute html =~ "Manual rows must be valid JSON"
      refute has_element?(view, ~s(button[disabled]), "Queue dry-run")

      html =
        render_submit(view, "queue_dry_run", %{
          "catalog_sync" =>
            Map.merge(
              %{
                "source_system_id" => source.id,
                "scope_kind" => scope_kind,
                "manual_rows" => ""
              },
              extra_form
            )
        })

      assert html =~ "Catalog dry-run queued"

      assert_enqueued(
        worker: DiscoverTickeraCatalogWorker,
        queue: :tickera_sync
      )

      assert catalog_sync_run_queued?(source.id, expected_scope)
    end
  end

  test "WordPress feed ID and updated-since scopes validate inputs", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    invalid_forms = [
      {"wordpress_feed_product", %{"product_id" => "0"}, "Enter a positive Woo product ID"},
      {"wordpress_feed_variation", %{"variation_id" => "-1"},
       "Enter a positive Woo variation ID"},
      {"wordpress_feed_event", %{"event_id" => "abc"}, "Enter a positive Tickera event ID"},
      {"wordpress_feed_updated_since", %{"updated_since" => "yesterday"},
       "Enter updated_since as RFC3339"}
    ]

    for {scope_kind, extra_form, message} <- invalid_forms do
      html =
        render_change(view, "update_form", %{
          "catalog_sync" =>
            Map.merge(
              %{
                "source_system_id" => source.id,
                "scope_kind" => scope_kind,
                "manual_rows" => ""
              },
              extra_form
            )
        })

      assert html =~ message
      assert has_element?(view, ~s(button[disabled]), "Queue dry-run")
    end
  end

  test "submit failures show sanitized visible feedback", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    html =
      render_submit(view, "queue_dry_run", %{
        "catalog_sync" => %{
          "source_system_id" => "",
          "scope_kind" => "woo_product",
          "manual_rows" => Jason.encode!(%{"events" => [], "catalog_rows" => []})
        }
      })

    assert html =~ "Select a source system before queueing"
    refute_enqueued(worker: DiscoverTickeraCatalogWorker)
  end

  test "admin sees preview findings and queues apply for ready run", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    snapshot = %{
      "dry_run_hash" => "ready-hash",
      "event_changes" => [
        %{
          "action" => "adopt_existing",
          "external_event_id" => 109_316,
          "name" => "Vroue wat Glo-retreat - PTA"
        }
      ],
      "ticket_type_changes" => [
        %{"action" => "adopt_existing", "name" => "Toegang", "external_ticket_type_id" => 109_740}
      ],
      "product_mapping_changes" => [],
      "findings" => [
        %{
          "severity" => "info",
          "code" => "vwg_pretoria_preserved",
          "message" => "VWG Pretoria existing product-level mapping will be preserved.",
          "tickera_event_id" => 109_316,
          "woo_product_id" => 109_740
        }
      ],
      "touched_event_ids" => [],
      "touched_product_keys" => [[109_740, nil]]
    }

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{"kind" => "manual_rows"},
          status: :dry_run_ready,
          dry_run_hash: "ready-hash",
          summary: %{"finding_count" => 1},
          plan_snapshot: snapshot
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "vwg_pretoria_preserved"
    assert html =~ "VWG Pretoria existing product-level mapping will be preserved."
    assert html =~ "Tickera event 109316"
    assert html =~ "Apply"

    html =
      render_click(view, "queue_apply", %{"run_id" => run.id, "dry_run_hash" => "ready-hash"})

    assert html =~ "Catalog apply queued"

    assert_enqueued(
      worker: ApplyTickeraCatalogWorker,
      queue: :tickera_sync,
      args: %{"run_id" => run.id, "dry_run_hash" => "ready-hash"}
    )
  end

  test "failed runs show bounded last_error in the runs table", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source.id,
        scope: %{"kind" => "wordpress_feed", "product_id" => 109_740},
        status: :failed,
        last_error: "catalog_feed_forbidden"
      },
      action: :create_dry_run,
      domain: Ingestion
    )

    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source.id,
        scope: %{"kind" => "wordpress_feed", "product_id" => 109_741},
        status: :failed,
        last_error: "secret=leaked https://example.test?sig=abc raw body"
      },
      action: :create_dry_run,
      domain: Ingestion
    )

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Failure reason"
    assert html =~ "catalog_feed_forbidden"
    assert html =~ "catalog_sync_failed"
    refute html =~ "secret=leaked"
    refute html =~ "https://example.test"
  end

  test "apply stays disabled when preview has blocking findings", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    snapshot = %{
      "dry_run_hash" => "blocked-hash",
      "event_changes" => [
        %{"action" => "create", "external_event_id" => 109_316, "ref" => "event:109316"}
      ],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [
        %{
          "severity" => "blocking",
          "code" => "existing_mapping_conflict",
          "message" => "Existing mapping conflict requires admin review."
        }
      ],
      "touched_event_ids" => [],
      "touched_product_keys" => []
    }

    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source.id,
        scope: %{"kind" => "manual_rows"},
        status: :dry_run_ready,
        dry_run_hash: "blocked-hash",
        summary: %{"finding_count" => 1},
        plan_snapshot: snapshot
      },
      action: :create_dry_run,
      domain: Ingestion
    )

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "existing_mapping_conflict"
    assert has_element?(view, ~s(button[disabled]), "Apply")
  end

  test "CatalogSyncLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/catalog_sync_live.ex")

    for forbidden <- [
          "WooCommerceClient",
          "WordPressFeedClient",
          "MappingResolver",
          "OrderUpserter",
          "Req",
          "Finch",
          "Tesla",
          "ProductMapping",
          "TickeraCatalogSyncRun"
        ] do
      refute source =~ forbidden
    end
  end

  defp catalog_sync_run_queued?(source_system_id, expected_scope) do
    TickeraCatalogSyncRun
    |> Ash.Query.filter(source_system_id == ^source_system_id)
    |> Ash.read!(domain: Ingestion)
    |> Enum.any?(fn run -> run.scope == expected_scope end)
  end

  defp sign_in_as(conn, user), do: Plug.Test.init_test_session(conn, %{current_user_id: user.id})

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
