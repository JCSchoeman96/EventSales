defmodule EventSalesWeb.PageController do
  use EventSalesWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
