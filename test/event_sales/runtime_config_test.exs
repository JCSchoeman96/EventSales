defmodule EventSales.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config_path Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    original_timezone = System.get_env("EVENTSALES_BUSINESS_TIMEZONE")
    original_currency = System.get_env("EVENTSALES_DEFAULT_CURRENCY")

    on_exit(fn ->
      restore_env("EVENTSALES_BUSINESS_TIMEZONE", original_timezone)
      restore_env("EVENTSALES_DEFAULT_CURRENCY", original_currency)
    end)

    :ok
  end

  test "runtime config reads business timezone and currency from env" do
    System.put_env("EVENTSALES_BUSINESS_TIMEZONE", "Africa/Johannesburg")
    System.put_env("EVENTSALES_DEFAULT_CURRENCY", "ZAR")

    app_config =
      @runtime_config_path
      |> Config.Reader.read!(env: :test)
      |> Keyword.get(:event_sales, [])

    assert Keyword.get(app_config, :business_timezone) == "Africa/Johannesburg"
    assert Keyword.get(app_config, :default_currency) == "ZAR"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
