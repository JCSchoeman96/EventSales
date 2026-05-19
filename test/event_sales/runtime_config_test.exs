defmodule EventSales.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config_path Path.expand("../../config/runtime.exs", __DIR__)
  @managed_env_keys [
    "DATABASE_URL",
    "DIRECT_DATABASE_URL",
    "EVENTSALES_BUSINESS_TIMEZONE",
    "EVENTSALES_DEFAULT_CURRENCY",
    "PHX_SERVER",
    "PHX_HOST",
    "SECRET_KEY_BASE",
    "WEBHOOK_PATH_TOKEN",
    "WOOCOMMERCE_WEBHOOK_SECRET",
    "TICKERA_DEFAULT_SITE_URL",
    "TICKERA_TIMEOUT_MS",
    "TICKERA_CONNECT_TIMEOUT_MS",
    "TICKERA_RECEIVE_TIMEOUT_MS",
    "TICKERA_PER_PAGE",
    "TICKERA_PAGE_DELAY_MS"
  ]

  setup do
    original_env =
      for key <- @managed_env_keys, into: %{} do
        {key, System.get_env(key)}
      end

    on_exit(fn ->
      Enum.each(original_env, fn {key, value} -> restore_env(key, value) end)
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

  test "prod runtime config keeps the direct migration path separate from the repo url" do
    System.put_env("DATABASE_URL", "ecto://pooled-user:pooled-pass@db.internal/event_sales")

    System.put_env(
      "DIRECT_DATABASE_URL",
      "ecto://direct-user:direct-pass@db.internal/event_sales"
    )

    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))
    System.put_env("PHX_HOST", "eventsales.example.com")
    System.put_env("WEBHOOK_PATH_TOKEN", "prod-webhook-token")
    System.put_env("WOOCOMMERCE_WEBHOOK_SECRET", "prod-webhook-secret")

    app_config =
      @runtime_config_path
      |> Config.Reader.read!(env: :prod)
      |> Keyword.get(:event_sales, [])

    repo_config = Keyword.fetch!(app_config, EventSales.Repo)

    assert Keyword.fetch!(repo_config, :url) ==
             "ecto://pooled-user:pooled-pass@db.internal/event_sales"

    assert Keyword.get(app_config, :direct_database_url) ==
             "ecto://direct-user:direct-pass@db.internal/event_sales"

    webhook_intake = Keyword.get(app_config, :webhook_intake, [])

    assert Keyword.get(webhook_intake, :path_token) == "prod-webhook-token"
    assert Keyword.get(webhook_intake, :secret) == "prod-webhook-secret"
  end

  test "prod runtime config reads Tickera API settings from env without a global API key" do
    System.put_env("DATABASE_URL", "ecto://pooled-user:pooled-pass@db.internal/event_sales")
    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))
    System.put_env("PHX_HOST", "eventsales.example.com")
    System.put_env("WEBHOOK_PATH_TOKEN", "prod-webhook-token")
    System.put_env("WOOCOMMERCE_WEBHOOK_SECRET", "prod-webhook-secret")
    System.put_env("TICKERA_DEFAULT_SITE_URL", "https://tickera.example.test")
    System.put_env("TICKERA_TIMEOUT_MS", "31000")
    System.put_env("TICKERA_CONNECT_TIMEOUT_MS", "6000")
    System.put_env("TICKERA_RECEIVE_TIMEOUT_MS", "32000")
    System.put_env("TICKERA_PER_PAGE", "75")
    System.put_env("TICKERA_PAGE_DELAY_MS", "125")

    app_config =
      @runtime_config_path
      |> Config.Reader.read!(env: :prod)
      |> Keyword.get(:event_sales, [])

    tickera_config = Keyword.fetch!(app_config, :tickera_api)

    assert Keyword.fetch!(tickera_config, :default_site_url) == "https://tickera.example.test"
    assert Keyword.fetch!(tickera_config, :timeout_ms) == 31_000
    assert Keyword.fetch!(tickera_config, :connect_timeout_ms) == 6_000
    assert Keyword.fetch!(tickera_config, :receive_timeout_ms) == 32_000
    assert Keyword.fetch!(tickera_config, :per_page) == 75
    assert Keyword.fetch!(tickera_config, :page_delay_ms) == 125
    refute Keyword.has_key?(tickera_config, :api_key)
    refute Keyword.has_key?(tickera_config, :max_pages)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
