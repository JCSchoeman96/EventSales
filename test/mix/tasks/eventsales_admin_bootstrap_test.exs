defmodule Mix.Tasks.Eventsales.Admin.BootstrapTest do
  use EventSales.DataCase, async: false

  import ExUnit.CaptureIO

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.{Role, User, UserRole}

  @email_key "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL"
  @password_key "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD"
  @name_key "EVENTSALES_BOOTSTRAP_ADMIN_NAME"
  @rotate_key "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD"
  @email "bootstrap-admin@example.test"
  @password "Test-Admin-Password-123!"
  @rotated_password "Rotated-Test-Password-123!"

  setup do
    for key <- [@email_key, @password_key, @name_key, @rotate_key] do
      original = System.get_env(key)

      on_exit(fn ->
        restore_env(key, original)
      end)
    end

    :ok
  end

  test "creates admin user, role, and user role from environment variables" do
    put_bootstrap_env()

    output = capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)

    user = user_by_email!(@email)
    assert user.name == "Bootstrap Admin"
    assert user.active
    assert Policies.global_admin?(user)
    assert role_by_name!(:admin)
    assert user_role(user, role_by_name!(:admin))
    assert authenticate(@email, @password)
    refute output =~ @email
    assert output =~ "admin user: created"
    assert output =~ "role: ensured"
    refute output =~ @password
  end

  test "is idempotent and does not duplicate role or user role" do
    put_bootstrap_env()

    capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)
    capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)

    user = user_by_email!(@email)
    role = role_by_name!(:admin)

    assert count_roles(:admin) == 1
    assert count_user_roles(user.id, role.id) == 1
  end

  test "refuses missing email" do
    System.delete_env(@email_key)
    System.put_env(@password_key, @password)

    assert_raise Mix.Error, ~r/#{@email_key} is required/, fn ->
      capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)
    end
  end

  test "refuses missing password" do
    System.put_env(@email_key, @email)
    System.delete_env(@password_key)

    assert_raise Mix.Error, ~r/#{@password_key} is required/, fn ->
      capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)
    end
  end

  test "refuses weak passwords" do
    System.put_env(@email_key, @email)
    System.put_env(@password_key, "weak-password")

    assert_raise Mix.Error, ~r/#{@password_key} is too weak/, fn ->
      capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)
    end
  end

  test "does not print password when validation fails" do
    weak_password = "weak-password"
    System.put_env(@email_key, @email)
    System.put_env(@password_key, weak_password)

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end
      end)

    refute output =~ weak_password
  end

  test "reactivates existing inactive user and preserves password when rotation is false" do
    existing = create_user!(@email, @password, active: false)
    System.put_env(@email_key, @email)
    System.put_env(@password_key, @rotated_password)
    System.put_env(@name_key, "Bootstrap Admin")

    output = capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)

    reloaded = Ash.get!(User, existing.id, domain: Accounts)
    assert reloaded.active
    assert authenticate(@email, @password)
    refute authenticate(@email, @rotated_password)
    refute output =~ "password: rotated"
    refute output =~ @rotated_password
  end

  test "rotates existing user password only when requested" do
    create_user!(@email, @password)
    System.put_env(@email_key, @email)
    System.put_env(@password_key, @rotated_password)
    System.put_env(@name_key, "Bootstrap Admin")
    System.put_env(@rotate_key, "true")

    output = capture_io(fn -> Mix.Tasks.Eventsales.Admin.Bootstrap.run([]) end)

    refute authenticate(@email, @password)
    assert authenticate(@email, @rotated_password)
    assert output =~ "password: rotated"
    refute output =~ @rotated_password
  end

  defp put_bootstrap_env do
    System.put_env(@email_key, @email)
    System.put_env(@password_key, @password)
    System.put_env(@name_key, "Bootstrap Admin")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp create_user!(email, password, attrs \\ []) do
    user =
      Ash.create!(
        User,
        %{
          email: email,
          name: Keyword.get(attrs, :name, "Existing Admin"),
          password: password,
          password_confirmation: password
        },
        action: :register_with_password,
        domain: Accounts
      )

    if Keyword.get(attrs, :active, true) do
      user
    else
      Ash.update!(user, %{active: false}, action: :update, domain: Accounts)
    end
  end

  defp authenticate(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{email: email, password: password}) do
      {:ok, %User{}} -> true
      _ -> false
    end
  end

  defp user_by_email!(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(domain: Accounts)
  end

  defp role_by_name!(name) do
    Role
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Accounts)
  end

  defp user_role(user, role) do
    UserRole
    |> Ash.Query.filter(user_id == ^user.id and role_id == ^role.id)
    |> Ash.read_one!(domain: Accounts)
  end

  defp count_roles(name) do
    Role
    |> Ash.Query.filter(name == ^name)
    |> Ash.read!(domain: Accounts)
    |> length()
  end

  defp count_user_roles(user_id, role_id) do
    UserRole
    |> Ash.Query.filter(user_id == ^user_id and role_id == ^role_id)
    |> Ash.read!(domain: Accounts)
    |> length()
  end
end
