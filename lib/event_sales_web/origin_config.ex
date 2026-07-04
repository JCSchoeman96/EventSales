defmodule EventSalesWeb.OriginConfig do
  @moduledoc false

  @spec check_origin(host :: String.t(), env_value :: String.t() | nil) :: [String.t()]
  def check_origin(host, nil), do: ["https://#{host}"]

  def check_origin(_host, origins) do
    origins
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
