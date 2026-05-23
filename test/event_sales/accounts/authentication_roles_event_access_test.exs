defmodule EventSales.Accounts.AuthenticationRolesEventAccessTest do
  use EventSales.DataCase, async: true

  alias EventSales.Accounts
  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.EventAccessGrant
  alias EventSales.Accounts.Resources.Role
  alias EventSales.Accounts.Resources.User
  alias EventSales.Accounts.Resources.UserRole

  @event_a "11111111-1111-1111-1111-111111111111"
  @event_b "22222222-2222-2222-2222-222222222222"

  test "admin can authenticate through AshAuthentication password strategy" do
    user = create_user!("admin-auth@example.com", "admin-pass-123")
    create_global_role!(user, :admin)

    strategy = AshAuthentication.Info.strategy!(User, :password)

    assert {:ok, signed_in} =
             AshAuthentication.Strategy.action(strategy, :sign_in, %{
               email: "admin-auth@example.com",
               password: "admin-pass-123"
             })

    assert signed_in.id == user.id
    assert Policies.global_admin?(signed_in)
  end

  test "global roles are limited to admin and staff" do
    assert create_role(:admin).name == :admin
    assert create_role(:staff).name == :staff

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(Role, %{name: :event_owner}, action: :create, domain: Accounts)
    end
  end

  test "event-scoped roles are limited to event_owner and event_staff" do
    user = create_user!("event-role@example.com")

    owner_grant = create_event_grant!(user, @event_a, :event_owner)
    staff_grant = create_event_grant!(user, @event_b, :event_staff)

    assert owner_grant.role == :event_owner
    assert staff_grant.role == :event_staff

    assert_raise Ash.Error.Invalid, fn ->
      create_event_grant!(user, @event_a, :admin)
    end
  end

  test "event owner is limited to the assigned event" do
    user = create_user!("owner-scope@example.com")
    create_event_grant!(user, @event_a, :event_owner)

    assert Policies.has_event_role?(user, @event_a, :event_owner)
    refute Policies.has_event_role?(user, @event_b, :event_owner)
  end

  test "expired grants deny access" do
    user = create_user!("expired-grant@example.com")

    create_event_grant!(user, @event_a, :event_owner,
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    )

    refute Policies.has_unexpired_event_grant?(user, @event_a, :event_owner)
    refute Policies.has_event_role?(user, @event_a, :event_owner)
  end

  test "revenue visibility defaults to admin-only" do
    admin = create_user!("revenue-admin@example.com")
    staff = create_user!("revenue-staff@example.com")
    owner = create_user!("revenue-owner@example.com")
    event_staff = create_user!("revenue-event-staff@example.com")

    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    create_event_grant!(owner, @event_a, :event_owner)
    create_event_grant!(event_staff, @event_a, :event_staff)

    assert Policies.can_view_revenue?(admin, @event_a)
    refute Policies.can_view_revenue?(staff, @event_a)
    refute Policies.can_view_revenue?(owner, @event_a)
    refute Policies.can_view_revenue?(event_staff, @event_a)
  end

  test "event dashboard access helper allows admin and assigned event roles only" do
    admin = create_user!("dashboard-helper-admin@example.com")
    global_staff = create_user!("dashboard-helper-global-staff@example.com")
    owner = create_user!("dashboard-helper-owner@example.com")
    event_staff = create_user!("dashboard-helper-event-staff@example.com")
    unassigned = create_user!("dashboard-helper-unassigned@example.com")

    create_global_role!(admin, :admin)
    create_global_role!(global_staff, :staff)
    create_event_grant!(owner, @event_a, :event_owner)
    create_event_grant!(event_staff, @event_a, :event_staff)

    assert Policies.can_access_event_dashboard?(admin, @event_a)
    assert Policies.can_access_event_dashboard?(owner, @event_a)
    assert Policies.can_access_event_dashboard?(event_staff, @event_a)

    refute Policies.can_access_event_dashboard?(global_staff, @event_a)
    refute Policies.can_access_event_dashboard?(unassigned, @event_a)
    refute Policies.can_access_event_dashboard?(owner, @event_b)
    refute Policies.can_access_event_dashboard?(owner, "not-a-uuid")
    refute Policies.can_access_event_dashboard?(admin, "not-a-uuid")

    assert Policies.event_dashboard_role(admin, @event_a) == :admin
    assert Policies.event_dashboard_role(owner, @event_a) == :event_owner
    assert Policies.event_dashboard_role(event_staff, @event_a) == :event_staff
    assert Policies.event_dashboard_role(global_staff, @event_a) == nil
    assert Policies.event_dashboard_role(admin, "not-a-uuid") == nil
  end

  test "event dashboard role prefers admin, then owner, then staff" do
    admin_owner = create_user!("dashboard-helper-admin-owner@example.com")
    owner_staff = create_user!("dashboard-helper-owner-staff@example.com")

    create_global_role!(admin_owner, :admin)
    create_event_grant!(admin_owner, @event_a, :event_owner)
    create_event_grant!(owner_staff, @event_a, :event_owner)
    create_event_grant!(owner_staff, @event_a, :event_staff)

    assert Policies.event_dashboard_role(admin_owner, @event_a) == :admin
    assert Policies.event_dashboard_role(owner_staff, @event_a) == :event_owner
  end

  test "expired grants do not authorize event dashboard access" do
    owner = create_user!("dashboard-helper-expired-owner@example.com")

    create_event_grant!(owner, @event_a, :event_owner,
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    )

    refute Policies.can_access_event_dashboard?(owner, @event_a)
    assert Policies.event_dashboard_role(owner, @event_a) == nil
  end

  test "duplicate role, user role, and active event grant are rejected" do
    user = create_user!("duplicates@example.com")
    role = create_role(:staff)

    assert_raise Ash.Error.Invalid, fn -> create_role(:staff) end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
        action: :create,
        domain: Accounts
      )
    end

    create_event_grant!(user, @event_a, :event_staff)

    assert_raise Ash.Error.Invalid, fn ->
      create_event_grant!(user, @event_a, :event_staff)
    end
  end

  test "duplicate user email is rejected case-insensitively" do
    create_user!("unique-email@example.com")

    assert_raise Ash.Error.Invalid, fn ->
      create_user!("UNIQUE-EMAIL@example.com")
    end
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

  defp create_role(name) do
    Ash.create!(Role, %{name: name}, action: :create, domain: Accounts)
  end

  defp create_global_role!(user, role_name) do
    role = create_role(role_name)

    Ash.create!(
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp create_event_grant!(user, event_id, role, opts \\ []) do
    attrs =
      %{
        user_id: user.id,
        event_id: event_id,
        role: role
      }
      |> Map.merge(Map.new(opts))

    Ash.create!(EventAccessGrant, attrs, action: :create, domain: Accounts)
  end
end
