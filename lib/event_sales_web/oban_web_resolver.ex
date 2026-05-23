defmodule EventSalesWeb.ObanWebResolver do
  @moduledoc """
  Read-only Oban Web access resolver for protected admin job visibility.
  """

  @behaviour Oban.Web.Resolver

  alias EventSales.Accounts.Policies

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_user]

  @impl true
  def resolve_access(user) do
    if Policies.global_admin?(user) do
      :read_only
    else
      {:forbidden, "/"}
    end
  end

  @impl true
  def resolve_instances(user) do
    if Policies.global_admin?(user), do: [Oban], else: []
  end

  @impl true
  def resolve_refresh(_user), do: 5
end
