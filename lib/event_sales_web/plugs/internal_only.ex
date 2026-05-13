defmodule EventSalesWeb.Plugs.InternalOnly do
  @moduledoc """
  Temporary internal-only guard for Slice 0.4 proof tooling.

  This is intentionally not the real admin authorization path. It exists only
  to keep the AshAdmin proof surface hidden unless the internal tool flag is
  enabled and the request originates from a local loopback address.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if ash_admin_enabled?() and internal_request?(conn) do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  defp ash_admin_enabled? do
    :event_sales
    |> Application.get_env(:internal_tools, [])
    |> Keyword.get(:ash_admin_enabled, false)
  end

  defp internal_request?(conn) do
    case conn.remote_ip do
      {127, 0, 0, 1} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      _ -> false
    end
  end
end
