defmodule EventSalesWeb.Live.Admin.Session do
  @moduledoc false

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User

  def current_user(%{"current_user_id" => user_id}) when is_binary(user_id) do
    case Ash.get(User, user_id, domain: Accounts) do
      {:ok, %User{active: true} = user} -> user
      _other -> nil
    end
  end

  def current_user(_session), do: nil

  def current_user_id(%{"current_user_id" => user_id}) when is_binary(user_id), do: user_id
  def current_user_id(%{current_user_id: user_id}) when is_binary(user_id), do: user_id
  def current_user_id(_session), do: "unknown"
end
