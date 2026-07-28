defmodule EventSalesWeb.Live.Admin.ProductMappingsLiveTest do
  use EventSalesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Catalog.VariationMappingResolver
  alias EventSales.Catalog.Resources.{ProductMapping, TicketType}
  alias EventSales.TestSupport.CatalogSyncRunHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})

    admin = create_user!("product-mappings-admin@example.com")
    staff = create_user!("product-mappings-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Mappings Live Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    mapping =
      create_mapping!(source, event, ticket, %{
        woo_product_id: 42_001,
        woo_variation_id: nil,
        current_label: "GA Ticket"
      })

    {:ok,
     admin: admin, staff: staff, source: source, event: event, ticket: ticket, mapping: mapping}
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/mappings")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects non-admin access", %{conn: conn, staff: staff} do
    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/mappings")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin can view read-only product mappings without PII fields", %{
    conn: conn,
    admin: admin,
    mapping: mapping
  } do
    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    assert html =~ "Product Mappings"
    assert html =~ "Catalog mapping visibility and controlled manual mapping creation."
    assert html =~ "Create manual mapping"
    assert html =~ "Mappings Live Event"
    assert html =~ "GA"
    assert html =~ Integer.to_string(mapping.woo_product_id)
    assert html =~ "GA Ticket"
    assert html =~ "true"

    refute html =~ "customer_email"
    refute html =~ "customer_name"
    refute html =~ "payment_gateway_transaction_id"
    refute html =~ "raw_payload"
    refute html =~ "private@example.test"
  end

  test "admin creates mapping with existing ticket type", %{
    conn: conn,
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    html =
      render_submit(view, "create_manual_mapping", %{
        "manual_mapping" => %{
          "source_system_id" => source.id,
          "event_id" => event.id,
          "ticket_type_mode" => "existing",
          "ticket_type_id" => ticket.id,
          "ticket_type_name" => "",
          "woo_product_id" => "104324",
          "woo_variation_id" => "",
          "label" => "VIP Comp",
          "source_status" => "private",
          "reason" => "VIP exception"
        }
      })

    assert html =~ "Manual mapping created"
    assert html =~ "104324"
    assert html =~ "VIP Comp"

    assert [mapping] =
             ProductMapping
             |> Ash.Query.filter(woo_product_id == 104_324)
             |> Ash.read!(domain: Catalog)

    assert mapping.ticket_type_id == ticket.id
    assert [audit] = audit_logs(:manual_mapping_created)
    assert audit.metadata["reason"] == "VIP exception"
  end

  test "prepared deep link locks exact identity and revalidates tampered submission", %{
    conn: conn,
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    {run, hash} = create_resolution_run!(source, 104_324, 501)
    assert {:ok, _revoked} = VariationMappingResolver.prepare(run.id, hash, actor: admin)

    path =
      "/admin/mappings?dry_run_hash=#{hash}&run_id=#{run.id}&woo_product_id=104324&woo_variation_id=501"

    {:ok, view, html} = conn |> sign_in_as(admin) |> live(path)

    assert html =~ "The selected dry-run was revoked before manual catalogue changes."
    assert html =~ "Reviewed variation"
    assert html =~ ~s(readonly)

    html =
      render_submit(view, "create_manual_mapping", %{
        "manual_mapping" => %{
          "source_system_id" => Ecto.UUID.generate(),
          "event_id" => event.id,
          "ticket_type_mode" => "existing",
          "ticket_type_id" => ticket.id,
          "ticket_type_name" => "",
          "woo_product_id" => "999999",
          "woo_variation_id" => "999999",
          "label" => "Tampered",
          "source_status" => "manual",
          "reason" => "Reviewed exact variation"
        }
      })

    assert html =~ "Mapping created and audited."
    assert html =~ "catalogue-dry-run --fresh"

    assert [mapping] =
             ProductMapping
             |> Ash.Query.filter(woo_product_id == 104_324 and woo_variation_id == 501)
             |> Ash.read!(domain: Catalog)

    assert mapping.source_system_id == source.id
  end

  test "admin creates new ticket type and mapping", %{
    conn: conn,
    admin: admin,
    source: source,
    event: event
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    html =
      render_submit(view, "create_manual_mapping", %{
        "manual_mapping" => %{
          "source_system_id" => source.id,
          "event_id" => event.id,
          "ticket_type_mode" => "new",
          "ticket_type_id" => "",
          "ticket_type_name" => "Pre-sale",
          "woo_product_id" => "104325",
          "woo_variation_id" => "501",
          "label" => "Pre-sale Batch A",
          "source_status" => "pre_sale",
          "reason" => "Pre-sale exception"
        }
      })

    assert html =~ "Manual mapping created"
    assert html =~ "104325"
    assert html =~ "Pre-sale Batch A"

    ticket =
      TicketType
      |> Ash.Query.filter(event_id == ^event.id and name == "Pre-sale")
      |> Ash.read_one!(domain: Catalog)

    assert ticket.external_ticket_type_kind == :woo_variation
    assert ticket.external_variation_id == 501
  end

  test "duplicate active mapping shows a safe error", %{
    conn: conn,
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    create_mapping!(source, event, ticket, %{woo_product_id: 104_324, current_label: "Existing"})

    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    html =
      render_submit(view, "create_manual_mapping", %{
        "manual_mapping" => %{
          "source_system_id" => source.id,
          "event_id" => event.id,
          "ticket_type_mode" => "existing",
          "ticket_type_id" => ticket.id,
          "ticket_type_name" => "",
          "woo_product_id" => "104324",
          "woo_variation_id" => "",
          "label" => "VIP Comp",
          "source_status" => "private",
          "reason" => "VIP exception"
        }
      })

    assert html =~ "An active mapping already exists for that Woo product"
    refute html =~ "Ash.Error"
    refute html =~ "Postgrex"
  end

  test "admin can filter mappings by event and product id", %{
    conn: conn,
    admin: admin,
    event: event,
    mapping: mapping
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    html =
      render_change(view, "filter", %{
        "filters" => %{"event_id" => event.id, "woo_product_id" => ""}
      })

    assert html =~ Integer.to_string(mapping.woo_product_id)

    html =
      render_change(view, "filter", %{
        "filters" => %{"event_id" => "", "woo_product_id" => "999999"}
      })

    assert html =~ "No product mappings match the current filters."
    refute html =~ Integer.to_string(mapping.woo_product_id)
  end

  test "ProductMappingsLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/product_mappings_live.ex")

    for forbidden <- [
          "EventSales.Catalog.MappingResolver",
          "WooCommerceClient",
          "OrderUpserter",
          "Repo",
          "Req",
          "Finch",
          "Tesla",
          "Ash.create(",
          "Ash.update",
          "Ash.destroy",
          "Repo.insert",
          "Repo.update",
          "Repo.delete"
        ] do
      refute source =~ forbidden
    end

    assert source =~ "ManualMappingCreator.create"
    assert source =~ "VariationMappingResolver.resolve"
  end

  test "internal mappings route remains read-only and internal-only" do
    source = File.read!("lib/event_sales_web/live/admin/mappings_live.ex")

    refute source =~ "create_manual_mapping"
    refute source =~ "ManualMappingCreator"
    refute source =~ "Ash.create("
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
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

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp audit_logs(event_type) do
    AuditLog
    |> Ash.Query.filter(event_type == ^event_type)
    |> Ash.read!(domain: Audit)
  end

  defp create_resolution_run!(source, product_id, variation_id) do
    snapshot = resolution_snapshot(source.id, product_id, variation_id)
    {:ok, _bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{dry_run_hash: hash, summary: %{}, plan_snapshot: snapshot}
      )

    {run, hash}
  end

  defp resolution_snapshot(source_system_id, product_id, variation_id) do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_system_id,
      "origin" => "human_admin",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [
        %{
          "action" => "create",
          "event_ref" => "tickera_event:109120",
          "ticket_type_ref" => "woo_variation:#{variation_id}",
          "source_system_id" => source_system_id,
          "woo_product_id" => product_id,
          "woo_variation_id" => variation_id,
          "original_label" => "Reviewed variation",
          "current_label" => "Reviewed variation",
          "active" => true
        }
      ],
      "findings" => [],
      "source_risks" => [],
      "historical_impact" => %{
        "totals" => %{
          "affected_pending_lines" => 0,
          "affected_quantity" => 0,
          "eligible_lines" => 0,
          "eligible_quantity" => 0,
          "deferred_lines" => 0,
          "deferred_quantity" => 0,
          "conflicting_lines" => 0,
          "conflicting_quantity" => 0,
          "already_mapped_lines" => 0,
          "already_mapped_quantity" => 0
        },
        "warning_count" => 0,
        "unresolved_destination_count" => 1,
        "unknown_classification_count" => 0,
        "destinations" => []
      },
      "identity_membership_proof" => %{
        "events" => [],
        "ticket_types" => [],
        "product_mappings" => []
      },
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" => [
          %{"woo_product_id" => product_id, "woo_variation_id" => variation_id}
        ]
      }
    }
  end
end
