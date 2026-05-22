defmodule EventSales.Accounts.PiiPolicyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.PiiPolicy

  alias EventSales.Accounts.Resources.{
    EventAccessGrant,
    Role,
    User,
    UserRole
  }

  @event_id "11111111-1111-1111-1111-111111111111"

  setup do
    original = Application.get_env(:event_sales, :staff_customer_pii_visibility)

    on_exit(fn ->
      restore_staff_visibility(original)
    end)

    :ok
  end

  test "admin can view full customer pii on explicit customer record surfaces" do
    admin = create_user!("pii-policy-admin@example.com")
    create_global_role!(admin, :admin)

    assert PiiPolicy.customer_pii_visibility(admin, context: :customer_record) == :full
  end

  test "staff customer pii defaults to masked" do
    staff = create_user!("pii-policy-staff-default@example.com")
    create_global_role!(staff, :staff)

    assert PiiPolicy.staff_customer_pii_visibility() == :masked
    assert PiiPolicy.customer_pii_visibility(staff, context: :customer_record) == :masked
  end

  test "staff customer pii can be configured to full" do
    Application.put_env(:event_sales, :staff_customer_pii_visibility, :full)

    staff = create_user!("pii-policy-staff-full@example.com")
    create_global_role!(staff, :staff)

    assert PiiPolicy.staff_customer_pii_visibility() == :full
    assert PiiPolicy.customer_pii_visibility(staff, context: :customer_record) == :full
  end

  test "invalid staff pii config fails safe to masked" do
    Application.put_env(:event_sales, :staff_customer_pii_visibility, :invalid)

    staff = create_user!("pii-policy-staff-invalid@example.com")
    create_global_role!(staff, :staff)

    assert PiiPolicy.staff_customer_pii_visibility() == :masked
    assert PiiPolicy.customer_pii_visibility(staff, context: :customer_record) == :masked
  end

  test "event owner and event staff get no customer pii with real event grants" do
    owner = create_user!("pii-policy-owner@example.com")
    event_staff = create_user!("pii-policy-event-staff@example.com")

    create_event_grant!(owner, @event_id, :event_owner)
    create_event_grant!(event_staff, @event_id, :event_staff)

    assert PiiPolicy.customer_pii_visibility(owner,
             context: :customer_record,
             event_id: @event_id
           ) == :none

    assert PiiPolicy.customer_pii_visibility(event_staff,
             context: :customer_record,
             event_id: @event_id
           ) == :none
  end

  test "unauthenticated actor gets no customer pii" do
    assert PiiPolicy.customer_pii_visibility(nil, context: :customer_record) == :none
  end

  test "aggregate and export contexts never expose pii" do
    admin = create_user!("pii-policy-context-admin@example.com")
    staff = create_user!("pii-policy-context-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    Application.put_env(:event_sales, :staff_customer_pii_visibility, :full)

    for actor <- [admin, staff, nil],
        context <- [:aggregate, :export] do
      assert PiiPolicy.customer_pii_visibility(actor, context: context, event_id: @event_id) ==
               :none
    end
  end

  test "raw webhook payload access is admin-only and not staff configurable" do
    admin = create_user!("pii-policy-raw-admin@example.com")
    staff = create_user!("pii-policy-raw-staff@example.com")
    owner = create_user!("pii-policy-raw-owner@example.com")
    event_staff = create_user!("pii-policy-raw-event-staff@example.com")

    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    create_event_grant!(owner, @event_id, :event_owner)
    create_event_grant!(event_staff, @event_id, :event_staff)
    Application.put_env(:event_sales, :staff_customer_pii_visibility, :full)

    assert PiiPolicy.can_view_raw_payload?(admin)
    refute PiiPolicy.can_view_raw_payload?(staff)
    refute PiiPolicy.can_view_raw_payload?(owner)
    refute PiiPolicy.can_view_raw_payload?(event_staff)
    refute PiiPolicy.can_view_raw_payload?(nil)
  end

  defp restore_staff_visibility(nil) do
    Application.delete_env(:event_sales, :staff_customer_pii_visibility)
  end

  defp restore_staff_visibility(value) do
    Application.put_env(:event_sales, :staff_customer_pii_visibility, value)
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
