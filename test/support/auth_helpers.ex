defmodule EventSales.TestSupport.AuthHelpers do
  @moduledoc """
  Test-only authentication helpers.

  These helpers mirror the existing LiveView test pattern and do not add
  runtime authentication behavior.
  """

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}

  @spec sign_in_as(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  @spec create_user!(String.t()) :: User.t()
  @spec create_user!(String.t(), String.t()) :: User.t()
  def create_user!(email, password \\ "valid-pass-123") do
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

  @spec create_global_role!(User.t(), atom()) :: UserRole.t()
  def create_global_role!(user, role_name) do
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
