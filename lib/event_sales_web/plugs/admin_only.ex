defmodule EventSalesWeb.Plugs.AdminOnly do
  @moduledoc """
  Requires an authenticated current user with the global admin role.
  """

  import Plug.Conn

  alias EventSales.Accounts.Policies

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: nil}} = conn, _opts) do
    conn
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  def call(%Plug.Conn{assigns: %{current_user: current_user}} = conn, _opts) do
    if Policies.global_admin?(current_user) do
      conn
    else
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end

  def call(conn, opts), do: call(assign(conn, :current_user, nil), opts)
end
