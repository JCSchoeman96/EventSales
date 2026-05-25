defmodule EventSalesWeb.PageController do
  use EventSalesWeb, :controller

  alias EventSales.Accounts.Policies

  plug EventSalesWeb.Plugs.LoadCurrentUser when action == :home

  def home(conn, _params) do
    render(conn, :home, admin_session?: Policies.global_admin?(conn.assigns.current_user))
  end
end
