defmodule EventSalesWeb.Live.Admin.CatalogSyncLiveTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker
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

  test "CatalogSyncLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/catalog_sync_live.ex")

    for forbidden <- [
          "WooCommerceClient",
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
