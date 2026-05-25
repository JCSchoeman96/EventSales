defmodule EventSalesWeb.Plugs.AdminOnly do
  @moduledoc """
  Requires an authenticated current user with the global admin role.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias EventSales.Accounts.Policies
  alias EventSalesWeb.AdminAccessHTML

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: nil}} = conn, _opts) do
    conn
    |> put_status(:unauthorized)
    |> put_view(html: AdminAccessHTML)
    |> render(:unauthorized)
    |> halt()
  end

  def call(%Plug.Conn{assigns: %{current_user: current_user}} = conn, _opts) do
    if Policies.global_admin?(current_user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> put_view(html: AdminAccessHTML)
      |> render(:forbidden)
      |> halt()
    end
  end

  def call(conn, opts), do: call(assign(conn, :current_user, nil), opts)
end
