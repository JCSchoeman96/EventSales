defmodule EventSales.Ingestion.WebhookDebugPiiTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts

  alias EventSales.Accounts.Resources.{
    EventAccessGrant,
    Role,
    User,
    UserRole
  }

  alias EventSales.Ingestion.WebhookDebug
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.TestSupport.SalesHelpers

  @event_id "11111111-1111-1111-1111-111111111111"

  setup do
    original = Application.get_env(:event_sales, :staff_customer_pii_visibility)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:event_sales, :staff_customer_pii_visibility)
        value -> Application.put_env(:event_sales, :staff_customer_pii_visibility, value)
      end
    end)

    source = SalesHelpers.create_source_system!()
    admin = create_user!("webhook-debug-pii-admin@example.com")
    staff = create_user!("webhook-debug-pii-staff@example.com")
    owner = create_user!("webhook-debug-pii-owner@example.com")
    event_staff = create_user!("webhook-debug-pii-event-staff@example.com")

    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    create_event_grant!(owner, @event_id, :event_owner)
    create_event_grant!(event_staff, @event_id, :event_staff)

    {:ok, source: source, admin: admin, staff: staff, owner: owner, event_staff: event_staff}
  end

  test "raw payload remains admin-only when staff pii visibility is full", %{
    source: source,
    admin: admin,
    staff: staff,
    owner: owner,
    event_staff: event_staff
  } do
    Application.put_env(:event_sales, :staff_customer_pii_visibility, :full)

    {:ok, event} =
      create_event(source, %{
        payload: %{"id" => 123, "billing" => %{"email" => "raw.private@example.test"}}
      })

    assert {:ok, payload} = WebhookDebug.get_payload(event.id, actor: admin)
    assert payload["billing"]["email"] == "raw.private@example.test"

    assert {:error, :forbidden} = WebhookDebug.get_payload(event.id, actor: staff)
    assert {:error, :forbidden} = WebhookDebug.get_payload(event.id, actor: owner)
    assert {:error, :forbidden} = WebhookDebug.get_payload(event.id, actor: event_staff)
    assert {:error, :forbidden} = WebhookDebug.get_payload(event.id, actor: nil)
  end

  test "webhook list rows expose metadata only", %{source: source, admin: admin} do
    {:ok, _event} =
      create_event(source, %{
        payload: %{"billing" => %{"email" => "raw.list@example.test"}},
        raw_body_size: 321
      })

    assert {:ok, %{rows: [row]}} = WebhookDebug.list_events(actor: admin)

    assert row.raw_body_size == 321
    refute Map.has_key?(row, :payload)
    refute inspect(row) =~ "raw.list@example.test"
  end

  defp create_event(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: "debug-pii-delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "debug-pii-hash-#{System.unique_integer([:positive])}",
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

  defp create_event_grant!(user, event_id, role) do
    Ash.create!(
      EventAccessGrant,
      %{user_id: user.id, event_id: event_id, role: role},
      action: :create,
      domain: Accounts
    )
  end
end
