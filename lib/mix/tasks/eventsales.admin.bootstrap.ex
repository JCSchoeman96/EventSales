defmodule Mix.Tasks.Eventsales.Admin.Bootstrap do
  @moduledoc """
  Bootstraps the first EventSales admin from environment variables.
  """

  use Mix.Task

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}

  @shortdoc "Bootstraps an EventSales admin account"

  @email_key "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL"
  @password_key "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD"
  @name_key "EVENTSALES_BOOTSTRAP_ADMIN_NAME"
  @rotate_key "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    email = required_env(@email_key)
    password = required_env(@password_key)
    name = System.get_env(@name_key, "EventSales Admin")
    rotate? = System.get_env(@rotate_key) == "true"

    validate_password!(password)

    {user, user_status, rotated?} = ensure_user(email, password, name, rotate?)
    role = ensure_admin_role()
    ensure_user_role(user, role)

    Mix.shell().info("bootstrap admin: #{email}")
    Mix.shell().info("user: #{user_status}")

    if rotated? do
      Mix.shell().info("password: rotated")
    end

    Mix.shell().info("role: ensured")
  end

  defp required_env(key) do
    case System.get_env(key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: Mix.raise("#{key} is required"), else: value

      _ ->
        Mix.raise("#{key} is required")
    end
  end

  defp validate_password!(password) do
    valid? =
      String.length(password) >= 16 and
        password =~ ~r/[A-Z]/ and
        password =~ ~r/[a-z]/ and
        password =~ ~r/[0-9]/ and
        password =~ ~r/[^A-Za-z0-9]/

    unless valid? do
      Mix.raise("#{@password_key} is too weak")
    end
  end

  defp ensure_user(email, password, name, rotate?) do
    case user_by_email(email) do
      nil ->
        user =
          Ash.create!(
            User,
            %{
              email: email,
              name: name,
              password: password,
              password_confirmation: password
            },
            action: :register_with_password,
            domain: Accounts
          )

        {user, "created", false}

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

  defp ensure_active(%User{active: true} = user), do: {user, "existing"}

  defp ensure_active(%User{} = user) do
    {Ash.update!(user, %{active: true}, action: :update, domain: Accounts), "updated"}
  end

  defp ensure_admin_role do
    case role_by_name(:admin) do
      nil ->
        Ash.create!(
          Role,
          %{name: :admin, description: "EventSales administrator"},
          action: :create,
          domain: Accounts
        )

      %Role{} = role ->
        role
    end
  end

  defp ensure_user_role(user, role) do
    case user_role(user.id, role.id) do
      nil ->
        Ash.create!(
          UserRole,
          %{user_id: user.id, role_id: role.id},
          action: :create,
          domain: Accounts
        )

      %UserRole{} = user_role ->
        user_role
    end
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
