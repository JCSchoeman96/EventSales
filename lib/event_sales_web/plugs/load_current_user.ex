defmodule EventSalesWeb.Plugs.LoadCurrentUser do
  @moduledoc """
  Loads the active current user identified by the session user id.

  This plug intentionally reads only the user id from the session. Roles and
  grants are never trusted from session data; authorization helpers query
  Postgres for current role and grant state.
  """

  import Plug.Conn

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    assign(conn, :current_user, load_current_user(get_session(conn, :current_user_id)))
  end

  defp load_current_user(nil), do: nil

  defp load_current_user(user_id) do
    case Ash.get(User, user_id, domain: Accounts) do
      {:ok, %User{active: true} = user} -> user
      _other -> nil
    end
  end
end
