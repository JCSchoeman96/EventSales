defmodule EventSales.Maintenance.AdminBootstrap do
  @moduledoc """
  Idempotently provisions the first EventSales administrator from runtime environment values.
  """

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}

  @email_key "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL"
  @password_key "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD"
  @name_key "EVENTSALES_BOOTSTRAP_ADMIN_NAME"
  @rotate_key "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD"

  @spec run!(map() | keyword()) :: %{
          user_status: :created | :existing | :updated,
          password_rotated?: boolean()
        }
  def run!(env \\ System.get_env()) do
    env = Map.new(env)
    email = required_env!(env, @email_key)
    password = required_env!(env, @password_key)
    name = optional_env(env, @name_key, "EventSales Admin")
    rotate? = Map.get(env, @rotate_key) == "true"

    validate_password!(password)

    {user, user_status, rotated?} = ensure_user(email, password, name, rotate?)
    role = ensure_admin_role()
    ensure_user_role(user, role)

    %{user_status: user_status, password_rotated?: rotated?}
  end

  defp required_env!(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise(ArgumentError, "#{key} is required"), else: value

      _ ->
        raise ArgumentError, "#{key} is required"
    end
  end

  defp optional_env(env, key, default) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> default
    end
  end

  defp validate_password!(password) do
    valid? =
      String.length(password) >= 16 and
        password =~ ~r/[A-Z]/ and
        password =~ ~r/[a-z]/ and
        password =~ ~r/[0-9]/ and
        password =~ ~r/[^A-Za-z0-9]/

    unless valid?, do: raise(ArgumentError, "#{@password_key} is too weak")
  end

  defp ensure_user(email, password, name, rotate?) do
    case user_by_email(email) do
      nil ->
        user =
          Ash.create!(
            User,
            %{email: email, name: name, password: password, password_confirmation: password},
            action: :register_with_password,
            domain: Accounts
          )

        {user, :created, false}

      %User{} = user ->
        {user, status} = ensure_active(user)

        if rotate? do
          rotated =
            Ash.update!(
              user,
              %{password: password, password_confirmation: password},
              action: :set_password,
              domain: Accounts
            )

          {rotated, status, true}
        else
          {user, status, false}
        end
    end
  end

  defp ensure_active(%User{active: true} = user), do: {user, :existing}

  defp ensure_active(%User{} = user) do
    {Ash.update!(user, %{active: true}, action: :update, domain: Accounts), :updated}
  end

  defp ensure_admin_role do
    role_by_name(:admin) ||
      Ash.create!(
        Role,
        %{name: :admin, description: "EventSales administrator"},
        action: :create,
        domain: Accounts
      )
  end

  defp ensure_user_role(user, role) do
    user_role(user.id, role.id) ||
      Ash.create!(
        UserRole,
        %{user_id: user.id, role_id: role.id},
        action: :create,
        domain: Accounts
      )
  end

  defp user_by_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(domain: Accounts)
  end

  defp role_by_name(name) do
    Role
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Accounts)
  end

  defp user_role(user_id, role_id) do
    UserRole
    |> Ash.Query.filter(user_id == ^user_id and role_id == ^role_id)
    |> Ash.read_one!(domain: Accounts)
  end
end
