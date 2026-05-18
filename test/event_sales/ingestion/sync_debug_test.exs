defmodule EventSales.Ingestion.SyncDebugTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.SyncDebug
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("sync-debug-admin@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Debug", slug: unique_slug("debug")})

    {:ok, admin: admin, source: source, event: event}
  end

  test "invalid event_id filter returns empty rows", %{admin: admin, source: source, event: event} do
    {:ok, _run} =
      Ash.create(
        SyncRun,
        %{
          source_system_id: source.id,
          event_id: event.id,
          date_from: ~U[2026-05-01 00:00:00Z],
          date_to: ~U[2026-05-02 00:00:00Z],
          sync_mode: :shallow,
          requested_via: :manual
        },
        action: :queue_manual_scoped,
        domain: Ingestion,
        context: %{scoped_manual_sync_now: ~U[2026-05-16 12:00:00Z]}
      )

    assert {:ok, %{rows: [], page: page}} =
             SyncDebug.list_runs(actor: admin, event_id: "not-a-uuid")

    assert page.has_next? == false
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
