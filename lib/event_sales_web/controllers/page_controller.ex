defmodule EventSalesWeb.PageController do
  use EventSalesWeb, :controller

  alias EventSales.Accounts.Policies

  plug EventSalesWeb.Plugs.LoadCurrentUser when action == :home

  def home(conn, _params) do
    current_user = conn.assigns.current_user

    render(conn, :home,
      admin_session?: Policies.global_admin?(current_user),
      signed_in?: not is_nil(current_user)
    )
  end
end
