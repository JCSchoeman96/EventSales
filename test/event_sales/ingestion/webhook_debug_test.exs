defmodule EventSales.Ingestion.WebhookDebugTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion.WebhookDebug
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    admin = create_user!("webhook-debug-admin@example.com")
    staff = create_user!("webhook-debug-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    {:ok, source: source, admin: admin, staff: staff}
  end

  test "admin can list webhook log with newest first pagination", %{source: source, admin: admin} do
    for index <- 1..30 do
      {:ok, _event} =
        create_event(source, %{
          delivery_id: "debug-delivery-#{index}",
          resource_id: "order-#{index}",
          received_at: DateTime.add(~U[2026-05-18 08:00:00Z], index, :second)
        })
    end

    assert {:ok, %{rows: rows, page: page}} = WebhookDebug.list_events(actor: admin, page: 1)
    assert length(rows) == 25
    assert page == %{page: 1, per_page: 25, has_next?: true, has_previous?: false}
    assert hd(rows).delivery_id == "debug-delivery-30"
    assert List.last(rows).delivery_id == "debug-delivery-6"

    assert {:ok, %{rows: next_rows, page: next_page}} =
             WebhookDebug.list_events(actor: admin, page: 2)

    assert Enum.map(next_rows, & &1.delivery_id) == [
             "debug-delivery-5",
             "debug-delivery-4",
             "debug-delivery-3",
             "debug-delivery-2",
             "debug-delivery-1"
           ]

    assert next_page == %{page: 2, per_page: 25, has_next?: false, has_previous?: true}
  end

  test "filters narrow webhook rows", %{source: source, admin: admin} do
    {:ok, failed} =
      create_event(source, %{
        delivery_id: "filter-delivery-failed",
        topic: "order.updated",
        resource_id: "777"
      })

    failed =
      Ash.update!(
        failed,
        %{failed_at: DateTime.utc_now(), error_message: "boom"},
        action: :mark_failed,
        domain: EventSales.Ingestion
      )

    {:ok, _processed} =
      create_event(source, %{
        delivery_id: "filter-delivery-processed",
        topic: "order.created",
        resource_id: "888"
      })

    assert {:ok, %{rows: [row]}} =
             WebhookDebug.list_events(
               actor: admin,
               status: "failed",
               topic: "order.updated",
               delivery_id: "filter-delivery-failed",
               resource_id: "777"
             )

    assert row.id == failed.id
    assert row.status == :failed
  end

  test "list webhook log requires admin actor", %{source: source, staff: staff} do
    {:ok, _event} = create_event(source, %{})

    assert {:error, :forbidden} = WebhookDebug.list_events(actor: staff)
    assert {:error, :forbidden} = WebhookDebug.list_events(actor: nil)
    assert {:error, :forbidden} = WebhookDebug.list_events()
  end

  test "raw payload is explicit admin-only access", %{source: source, admin: admin, staff: staff} do
    {:ok, event} =
      create_event(source, %{
        payload: %{"id" => 123, "billing" => %{"email" => "hidden@example.test"}}
      })

    assert {:ok, payload} = WebhookDebug.get_payload(event.id, actor: admin)
    assert payload["id"] == 123
    assert payload["billing"]["email"] == "hidden@example.test"

    assert {:error, :forbidden} = WebhookDebug.get_payload(event.id, actor: staff)
    assert {:error, :forbidden} = WebhookDebug.get_payload(event.id, actor: nil)
  end

  defp create_event(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: "debug-delivery-#{System.unique_integer([:positive])}",
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
