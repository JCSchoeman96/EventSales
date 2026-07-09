defmodule EventSalesWeb.Live.Admin.CatalogSyncLiveTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
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
    assert has_element?(view, ~s(button[phx-click="queue_apply"][disabled]), "Apply")
  end

  test "preview findings render safe review identifiers and allowlisted metadata only", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    snapshot = %{
      "dry_run_hash" => "review-hash",
      "event_changes" => [
        %{"action" => "create", "external_event_id" => 108_000, "ref" => "event:108000"}
      ],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [
        %{
          "severity" => "blocking",
          "code" => "ambiguous_variation_ticket_type_name",
          "message" =>
            "Published product variation could not produce a distinct TicketType name.",
          "tickera_event_id" => 108_000,
          "woo_product_id" => 108_657,
          "woo_variation_id" => 109_159,
          "metadata" => %{
            "reason" => "missing_variation_title",
            "raw_payload" => "must-not-render",
            "headers" => "authorization: secret",
            "signed_url" => "https://example.test?sig=secret",
            "customer_email" => "private@example.test",
            "payment_token" => "tok_private",
            "delivery_token" => "delivery_private"
          }
        },
        %{
          "severity" => "blocking",
          "code" => "duplicate_ticket_type_name",
          "message" => "Multiple catalog rows normalize to the same TicketType name.",
          "tickera_event_id" => nil,
          "woo_product_id" => nil,
          "woo_variation_id" => nil,
          "metadata" => %{"ticket_type_name" => "LBL – Nelspruit [Kaartjie]"}
        }
      ],
      "touched_event_ids" => [],
      "touched_product_keys" => []
    }

    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source.id,
        scope: %{"kind" => "wordpress_feed", "mode" => "full"},
        status: :dry_run_ready,
        dry_run_hash: "review-hash",
        summary: %{"finding_count" => 2},
        plan_snapshot: snapshot
      },
      action: :create_dry_run,
      domain: Ingestion
    )

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Finding review report"
    assert html =~ "Tickera event ID"
    assert html =~ "Woo product ID"
    assert html =~ "Woo variation ID"
    assert html =~ "ambiguous_variation_ticket_type_name"
    assert html =~ "Published product variation could not produce a distinct TicketType name."
    assert html =~ "108000"
    assert html =~ "108657"
    assert html =~ "109159"
    assert html =~ "missing_variation_title"
    assert html =~ "duplicate_ticket_type_name"
    assert html =~ "LBL – Nelspruit [Kaartjie]"

    assert html =~
             "blocking | ambiguous_variation_ticket_type_name | 108000 | 108657 | 109159 | missing_variation_title | -"

    assert html =~
             "blocking | duplicate_ticket_type_name | - | - | - | - | LBL – Nelspruit [Kaartjie]"

    refute html =~ "must-not-render"
    refute html =~ "authorization: secret"
    refute html =~ "https://example.test"
    refute html =~ "private@example.test"
    refute html =~ "tok_private"
    refute html =~ "delivery_private"
    assert has_element?(view, ~s(button[phx-click="queue_apply"][disabled]), "Apply")
  end

  test "apply stays disabled when dry-run preview is missing", %{
    conn: conn,
    admin: admin,
    source: source
  } do
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

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "missing-preview-hash"
    assert has_element?(view, ~s(button[phx-click="queue_apply"][disabled]), "Apply")
  end

  test "mapping conflict section renders safe stale mapping details and deactivates safe rows", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    %{mapping: mapping} = create_stale_mapping_conflict!(source, 109_165)
    run = create_mapping_conflict_run!(source, "conflict-hash", 109_165)

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Mapping conflict resolution"
    assert html =~ run.id
    assert html =~ "109132"
    assert html =~ "109165"
    assert html =~ "109120"
    assert html =~ "Lynette Beer LIVE - MP"
    assert html =~ "108658"
    assert html =~ "MP Ticket 109165"
    assert html =~ mapping.id
    assert html =~ "order_item_count"
    assert html =~ "0"
    assert html =~ "Deactivate stale mapping"

    html =
      render_click(view, "deactivate_stale_mapping", %{
        "run_id" => run.id,
        "dry_run_hash" => "conflict-hash",
        "woo_product_id" => "109132",
        "woo_variation_id" => "109165"
      })

    assert html =~ "Stale mapping deactivated. Rerun full-feed dry-run."
    refute Ash.get!(ProductMapping, mapping.id, domain: Catalog).active
  end

  test "mapping conflict section hides actions for blocked guardrail states", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    history = create_stale_mapping_conflict!(source, 109_165)
    create_order_item!(source, history.event, history.ticket, 109_165)
    create_mapping_conflict_run!(source, "history-hash", 109_165)

    inactive = create_stale_mapping_conflict!(source, 109_167)
    Ash.update!(inactive.mapping, %{}, action: :deactivate, domain: Catalog, actor: admin)
    create_mapping_conflict_run!(source, "inactive-hash", 109_167)

    create_mapping_conflict_run!(source, "stale-hash", 109_169, %{
      plan_snapshot: mapping_conflict_snapshot("different-hash", 109_169)
    })

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "order_history_exists"
    assert html =~ "Review cutover"
    assert html =~ "mapping_not_active"
    assert html =~ "stale_preview"

    refute has_element?(
             view,
             ~s(button[phx-click="deactivate_stale_mapping"][phx-value-woo_variation_id="109165"])
           )

    refute has_element?(
             view,
             ~s(button[phx-click="deactivate_stale_mapping"][phx-value-woo_variation_id="109167"])
           )

    refute has_element?(
             view,
             ~s(button[phx-click="deactivate_stale_mapping"][phx-value-woo_variation_id="109169"])
           )
  end

  test "reviewed cutover action deactivates mapping without changing order items", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    history = create_stale_mapping_conflict!(source, 109_165)
    order_item = create_order_item!(source, history.event, history.ticket, 109_165)
    run = create_mapping_conflict_run!(source, "cutover-hash", 109_165)

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Review cutover"

    html =
      render_submit(view, "cutover_stale_mapping", %{
        "run_id" => run.id,
        "dry_run_hash" => "cutover-hash",
        "woo_product_id" => "109132",
        "woo_variation_id" => "109165",
        "stale_mapped_event_external_id" => "108658",
        "feed_tickera_event_id" => "109120",
        "confirmation" => "CUTOVER 109132/109165 FROM 108658 TO 109120"
      })

    assert html =~
             "Stale mapping cut over. Existing order items were not changed. Rerun full-feed dry-run."

    refute Ash.get!(ProductMapping, history.mapping.id, domain: Catalog).active
    assert Ash.get!(OrderItem, order_item.id, domain: Sales).event_id == history.event.id
  end

  test "confirmed order correction preview renders safe fields and applies exact correction", %{
    conn: conn,
    admin: admin,
    source: source
  } do
    ctx = create_order_correction_context!(source)

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/catalog-sync")

    assert html =~ "Confirmed order attribution correction"
    assert html =~ "113834"
    assert html =~ "109132"
    assert html =~ "109167"
    assert html =~ "108658"
    assert html =~ "109120"
    assert html =~ "MP Ticket"
    assert html =~ "WR Ticket"
    assert html =~ ctx.order_item.id
    refute html =~ "catalog-sync-admin@example.com"
    refute html =~ "payment"
    refute html =~ "raw_payload"

    html =
      render_submit(view, "correct_order_attribution", %{
        "confirmation" => "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120"
      })

    assert html =~ "Order attribution corrected for Woo order 113834."
    corrected = Ash.get!(OrderItem, ctx.order_item.id, domain: Sales)
    assert corrected.event_id == ctx.wr_event.id
    assert corrected.ticket_type_id == ctx.wr_ticket.id
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

  defp create_stale_mapping_conflict!(source, variation_id) do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        slug: "lynette-beer-live-mp-#{variation_id}",
        external_event_id: mapped_external_event_id(variation_id),
        external_event_kind: :tickera_event
      })

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "MP Ticket #{variation_id}"})

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 109_132,
          woo_variation_id: variation_id,
          original_label: ticket.name,
          current_label: ticket.name,
          active: true
        },
        action: :create,
        domain: Catalog
      )

    %{event: event, ticket: ticket, mapping: mapping}
  end

  defp mapped_external_event_id(109_165), do: 108_658
  defp mapped_external_event_id(variation_id), do: 108_658 + variation_id

  defp create_mapping_conflict_run!(source, hash, variation_id, attrs \\ %{}) do
    defaults = %{
      source_system_id: source.id,
      scope: %{"kind" => "wordpress_feed", "mode" => "full"},
      status: :dry_run_ready,
      dry_run_hash: hash,
      summary: %{"finding_count" => 1},
      plan_snapshot: mapping_conflict_snapshot(hash, variation_id)
    }

    Ash.create!(TickeraCatalogSyncRun, Map.merge(defaults, attrs),
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp mapping_conflict_snapshot(hash, variation_id) do
    %{
      "dry_run_hash" => hash,
      "event_changes" => [],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [
        %{
          "severity" => "blocking",
          "code" => "existing_mapping_conflict",
          "message" => "Active ProductMapping points at a different catalog identity.",
          "tickera_event_id" => 109_120,
          "woo_product_id" => 109_132,
          "woo_variation_id" => variation_id
        }
      ],
      "touched_event_ids" => [],
      "touched_product_keys" => [[109_132, variation_id]]
    }
  end

  defp create_order_item!(source, event, ticket, variation_id) do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => 109_132,
      "variation_id" => variation_id,
      "name" => "Historical ticket",
      "quantity" => 1,
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0.00"
    }

    SalesHelpers.create_order_item_from_line!(order, line, %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      mapping_status: :mapped,
      item_kind: :ticket
    })
  end

  defp create_order_correction_context!(source) do
    mp_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        external_event_id: 108_658,
        external_event_kind: :tickera_event
      })

    mp_ticket = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP Ticket"})

    wr_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - WR",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    wr_ticket =
      SalesHelpers.create_ticket_type!(wr_event, %{
        name: "WR Ticket",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 109_167,
        external_product_id: 109_132,
        external_variation_id: 109_167
      })

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: wr_event.id,
        ticket_type_id: wr_ticket.id,
        woo_product_id: 109_132,
        woo_variation_id: 109_167,
        original_label: "WR Ticket",
        current_label: "WR Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    order =
      :order_completed
      |> SalesHelpers.normalized_order_attrs_from_fixture!(source)
      |> Map.merge(%{woo_order_id: 113_834, order_number: "113834"})
      |> then(&Ash.create!(Order, &1, action: :create_normalized, domain: Sales))

    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => 109_132,
      "variation_id" => 109_167,
      "name" => "WR Ticket",
      "quantity" => 5,
      "subtotal" => "500.00",
      "total" => "500.00",
      "discount_total" => "0.00"
    }

    order_item =
      SalesHelpers.create_order_item_from_line!(order, line, %{
        event_id: mp_event.id,
        ticket_type_id: mp_ticket.id,
        mapping_status: :mapped,
        item_kind: :ticket
      })

    %{order_item: order_item, wr_event: wr_event, wr_ticket: wr_ticket}
  end
end
