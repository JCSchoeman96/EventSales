defmodule EventSalesWeb.Live.Admin.SyncLiveTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.Workers.ReconcileOrdersWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    ManualActionRateLimiter.reset_for_test!()
    Repo.delete_all(from(j in Oban.Job))

    on_exit(fn ->
      ManualActionRateLimiter.reset_for_test!()
      Repo.delete_all(from(j in Oban.Job))
    end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Sync Live Event",
        slug: unique_slug("sync-live")
      })

    {:ok, source: source, event: event}
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/sync")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("sync-live-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/sync")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin sees recent runs with status counts and pause metadata", %{
    conn: conn,
    source: source,
    event: event
  } do
    admin = create_user!("sync-live-admin@example.com")
    create_global_role!(admin, :admin)

    {:ok, paused_run} =
      queue_manual(
        %{
          source_system_id: source.id,
          event_id: event.id,
          date_from: ~U[2026-05-01 00:00:00Z],
          date_to: ~U[2026-05-02 00:00:00Z],
          sync_mode: :shallow
        },
        now: ~U[2026-05-16 12:00:00Z]
      )

    paused_run =
      paused_run
      |> Ash.update!(%{}, action: :start, domain: Ingestion)
      |> Ash.update!(%{orders_seen_count: 3, orders_matched_count: 2, orders_upserted_count: 1},
        action: :record_counts,
        domain: Ingestion
      )
      |> Ash.update!(
        %{
          paused_until: ~U[2026-05-18 09:00:00Z],
          pause_reason: :rate_limited,
          last_error: "429"
        },
        action: :pause,
        domain: Ingestion
      )

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/sync")

    assert html =~ "Manual Sync"
    assert html =~ to_string(paused_run.status)
    assert html =~ "seen 3"
    assert html =~ "matched 2"
    assert html =~ "upserted 1"
    assert html =~ "rate_limited"
    assert html =~ "429"
  end

  test "scope validation rejects incomplete form before enqueue", %{conn: conn} do
    admin = create_user!("sync-live-scope@example.com")
    create_global_role!(admin, :admin)

    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/sync")

    assert render_click(view, "confirm_sync") =~ "Confirm sync"

    html = render_click(view, "queue_sync")
    assert html =~ "Sync requires an event"
    refute_enqueued(worker: ReconcileOrdersWorker)

    assert {:ok, []} =
             AuditLog
             |> Ash.Query.filter(event_type == :manual_sync_requested)
             |> Ash.read(domain: Audit)
  end

  test "manual sync requires confirmation, enqueues, audits, and rate limits", %{
    conn: conn,
    event: event
  } do
    admin = create_user!("sync-live-queue@example.com")
    create_global_role!(admin, :admin)

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/sync")

    assert html =~ "Queue sync"

    html =
      render_change(view, "update_form", %{
        "sync" => %{
          "event_id" => event.id,
          "date_from" => "2026-05-01",
          "date_to" => "2026-05-02",
          "sync_mode" => "shallow"
        }
      })

    assert html =~ event.name
    assert render_click(view, "confirm_sync") =~ "Confirm sync"
    refute_enqueued(worker: ReconcileOrdersWorker)

    html = render_click(view, "queue_sync")
    assert html =~ "Sync queued"
    assert_enqueued(worker: ReconcileOrdersWorker)

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(event_type == :manual_sync_requested)
             |> Ash.read(domain: Audit)

    assert audit.metadata["scope"] == "event"
    assert audit.metadata["event_id"] == event.id
    assert audit.metadata["sync_mode"] == "shallow"
    assert audit.metadata["result"] == "queued"

    assert render_click(view, "confirm_sync") =~ "Confirm sync"
    assert render_click(view, "queue_sync") =~ "Try again shortly"
    assert length(all_enqueued(worker: ReconcileOrdersWorker)) == 1
  end

  test "SyncLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/sync_live.ex")

    for forbidden <- [
          "OrderUpserter",
          "WooCommerceClient",
          "WooCommerce",
          "Req",
          "Finch",
          "HTTPoison",
          "Redix",
          "Repo",
          "ingestion_sync_runs"
        ] do
      refute source =~ forbidden
    end
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  defp queue_manual(attrs, opts) do
    now = Keyword.get(opts, :now, ~U[2026-05-16 12:00:00Z])

    SyncRun
    |> Ash.Changeset.for_create(:queue_manual_scoped, attrs)
    |> Ash.create(domain: Ingestion, context: %{scoped_manual_sync_now: now})
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Test User",
        password: password,
        password_confirmation: password
      },
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

    Ash.create!(
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
