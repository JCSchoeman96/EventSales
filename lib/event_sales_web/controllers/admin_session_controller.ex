defmodule EventSalesWeb.AdminSessionController do
  @moduledoc """
  Controller-backed admin session flow.
  """

  use EventSalesWeb, :controller

  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.User
  alias EventSalesWeb.Plugs.LoadCurrentUser

  plug LoadCurrentUser when action in [:new]

  @generic_error "Invalid email, password, or access"

  def new(%{assigns: %{current_user: current_user}} = conn, _params) do
    if Policies.global_admin?(current_user) do
      redirect(conn, to: ~p"/admin/dashboard")
    else
      render(conn, :new, email: "")
    end
  end

  def create(conn, %{"admin_session" => params}) do
    email = params["email"] || ""
    password = params["password"] || ""

    case authenticate_admin(email, password) do
      {:ok, %User{} = user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:current_user_id, user.id)
        |> redirect(to: ~p"/admin/dashboard")

      :error ->
        invalid_login(conn)
    end
  end

  def create(conn, _params), do: invalid_login(conn)

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end

  defp authenticate_admin(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    with {:ok, %User{active: true} = user} <-
           AshAuthentication.Strategy.action(strategy, :sign_in, %{
             email: email,
             password: password
           }),
         true <- Policies.global_admin?(user) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp invalid_login(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_flash(:error, @generic_error)
    |> render(:new, email: "")
  end
end
