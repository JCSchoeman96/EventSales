defmodule EventSalesWeb.Live.Admin.WebhooksLiveTest do
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
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
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

    {:ok, source: SalesHelpers.create_source_system!()}
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/webhooks")
    assert response(conn, 401) == "Unauthorized"
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("webhooks-live-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/webhooks")

    assert response(conn, 403) == "Forbidden"
  end

  test "admin can view paginated log and filter rows", %{conn: conn, source: source} do
    admin = create_user!("webhooks-live-admin@example.com")
    create_global_role!(admin, :admin)

    for index <- 1..30 do
      {:ok, event} =
        create_event(source, %{
          delivery_id: "live-delivery-#{index}",
          resource_id: "live-order-#{index}",
          received_at: DateTime.add(~U[2026-05-18 08:00:00Z], index, :second)
        })

      if index == 30, do: mark_failed!(event)
    end

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/webhooks")

    assert html =~ "Webhook Debug"
    assert html =~ "live-delivery-30"
    assert html =~ "live-delivery-6"
    refute html =~ "live-delivery-5"

    html = render_click(view, "next_page")
    assert html =~ "live-delivery-5"
    refute html =~ "live-delivery-30"

    html =
      render_change(view, "filter", %{
        "filters" => %{
          "status" => "failed",
          "topic" => "",
          "delivery_id" => "",
          "resource_id" => ""
        }
      })

    assert html =~ "live-delivery-30"
    refute html =~ "live-delivery-29"
  end

  test "raw payload is hidden until explicit admin reveal", %{conn: conn, source: source} do
    admin = create_user!("webhooks-live-payload@example.com")
    create_global_role!(admin, :admin)

    {:ok, event} =
      create_event(source, %{
        delivery_id: "payload-delivery",
        payload: %{"id" => 123, "private_marker" => "payload-visible-only-after-click"}
      })

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/webhooks")

    assert html =~ "payload-delivery"
    refute html =~ "payload-visible-only-after-click"

    html = render_click(view, "show_payload", %{"id" => event.id})
    assert html =~ "payload-visible-only-after-click"

    html = render_click(view, "hide_payload", %{})
    refute html =~ "payload-visible-only-after-click"
  end

  test "large raw payload reveal is display-truncated", %{conn: conn, source: source} do
    admin = create_user!("webhooks-live-large-payload@example.com")
    create_global_role!(admin, :admin)
    large_value = String.duplicate("x", 25_000)

    {:ok, event} =
      create_event(source, %{
        delivery_id: "large-payload-delivery",
        payload: %{"id" => 123, "large_value" => large_value, "tail_marker" => "must-not-render"}
      })

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/webhooks")

    refute html =~ "[truncated]"
    refute html =~ "must-not-render"

    html = render_click(view, "show_payload", %{"id" => event.id})
    assert html =~ "[truncated]"
    assert html =~ String.duplicate("x", 100)
    refute html =~ "must-not-render"
  end

  test "failed replay requires confirmation, enqueues, audits, and rate limits", %{
    conn: conn,
    source: source
  } do
    admin = create_user!("webhooks-live-replay@example.com")
    create_global_role!(admin, :admin)
    failed = source |> create_event!() |> mark_failed!()

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/webhooks")

    assert html =~ "Replay"
    assert render_click(view, "confirm_replay", %{"id" => failed.id}) =~ "Confirm replay"
    assert [] = all_enqueued(worker: ProcessWebhookWorker)

    html = render_click(view, "replay", %{"id" => failed.id})
    assert html =~ "Replay queued"
    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => failed.id})

    assert [audit] = Ash.read!(AuditLog, domain: Audit)
    assert audit.metadata["result"] == "queued"

    second_failed = source |> create_event!() |> mark_failed!()
    assert render_click(view, "confirm_replay", %{"id" => second_failed.id}) =~ "Confirm replay"
    assert render_click(view, "replay", %{"id" => second_failed.id}) =~ "Try again shortly"
  end

  test "WebhooksLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/webhooks_live.ex")

    for forbidden <- [
          "WebhookProcessor",
          "OrderUpserter",
          "WooCommerce",
          "Req",
          "Finch",
          "HTTPoison",
          "Redix",
          "Repo",
          "ingestion_webhook_events"
        ] do
      refute source =~ forbidden
    end
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  defp create_event!(source, attrs \\ %{}) do
    {:ok, event} = create_event(source, attrs)
    event
  end

  defp create_event(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: "live-delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "hash-#{System.unique_integer([:positive])}",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: ~U[2026-05-01 08:05:00Z],
      sanitized_headers_snapshot: %{}
    }

    WebhookEventStore.create_receive(Map.merge(defaults, attrs))
  end

  defp mark_failed!(event) do
    event =
      Ash.update!(
        event,
        %{processing_attempt_count: 1, processing_started_at: ~U[2026-05-18 08:01:00Z]},
        action: :mark_processing,
        domain: Ingestion
      )

    Ash.update!(
      event,
      %{failed_at: ~U[2026-05-18 08:02:00Z], error_message: "failed"},
      action: :mark_failed,
      domain: Ingestion
    )
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
end
