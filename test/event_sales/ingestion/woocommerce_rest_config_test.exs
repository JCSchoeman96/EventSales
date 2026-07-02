defmodule EventSales.Ingestion.WooCommerceRestConfigTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.WooCommerceRestConfig

  setup do
    original = Application.get_env(:event_sales, :woocommerce_rest)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:event_sales, :woocommerce_rest)
        value -> Application.put_env(:event_sales, :woocommerce_rest, value)
      end
    end)

    {:ok, original: original}
  end

  test "configured? is true when REST config and max concurrency are valid" do
    Application.put_env(:event_sales, :woocommerce_rest,
      base_url: "https://woo.example.test",
      consumer_key: "ck_test",
      consumer_secret: "cs_test",
      max_concurrency: 2
    )

    assert WooCommerceRestConfig.configured?()
    assert :ok = WooCommerceRestConfig.validate_for_live_cutover!()
  end

  test "validate_for_live_cutover returns error when max concurrency is not 2" do
    Application.put_env(:event_sales, :woocommerce_rest,
      base_url: "https://woo.example.test",
      consumer_key: "ck_test",
      consumer_secret: "cs_test",
      max_concurrency: 3
    )

    refute WooCommerceRestConfig.configured?()

    assert {:error, {:invalid_max_concurrency, 3}} =
             WooCommerceRestConfig.validate_for_live_cutover()
  end

  test "validate_for_live_cutover returns error when credentials are missing" do
    Application.put_env(:event_sales, :woocommerce_rest,
      base_url: nil,
      consumer_key: nil,
      consumer_secret: nil,
      max_concurrency: 2
    )

    refute WooCommerceRestConfig.configured?()

    assert {:error, :misconfigured} = WooCommerceRestConfig.validate_for_live_cutover()
  end
end
