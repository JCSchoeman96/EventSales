defmodule EventSales.Maintenance.ProductionSmokeTest do
  use ExUnit.Case, async: true

  alias EventSales.Maintenance.ProductionSmoke
  alias EventSales.Maintenance.ProductionSmoke.Http

  @env %{
    "RAILWAY_PUBLIC_DOMAIN" => "eventsales-production.up.railway.app",
    "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL" => "admin@example.test",
    "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD" => "Admin-Password-123!",
    "WEBHOOK_PATH_TOKEN" => "path-token",
    "WOOCOMMERCE_WEBHOOK_SECRET" => "webhook-secret"
  }

  test "builds smoke configuration from Railway and secret runtime variables" do
    config = ProductionSmoke.config!(@env)

    assert config.base_url == "https://eventsales-production.up.railway.app"
    assert config.admin_email == "admin@example.test"
    assert config.admin_password == "Admin-Password-123!"
    assert config.webhook_path_token == "path-token"
    assert config.webhook_secret == "webhook-secret"
  end

  test "allows an explicit HTTPS smoke base URL" do
    config =
      ProductionSmoke.config!(
        Map.put(@env, "EVENTSALES_PUBLIC_BASE_URL", "https://sales.example.test/")
      )

    assert config.base_url == "https://sales.example.test"
  end

  test "rejects missing variables without exposing configured secret values" do
    env = Map.delete(@env, "WEBHOOK_PATH_TOKEN")

    error = assert_raise ProductionSmoke.Error, fn -> ProductionSmoke.config!(env) end

    assert error.message =~ "WEBHOOK_PATH_TOKEN"
    refute error.message =~ @env["EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD"]
    refute error.message =~ @env["WOOCOMMERCE_WEBHOOK_SECRET"]
  end

  test "runs named checks in order and emits only safe labels" do
    caller = self()

    assert :ok =
             ProductionSmoke.run!(
               env: @env,
               checks: [
                 {"postgres",
                  fn _config ->
                    send(caller, :postgres)
                    :ok
                  end},
                 {"redis",
                  fn _config ->
                    assert_received :postgres
                    :ok
                  end}
               ],
               output: fn line -> send(caller, {:output, line}) end
             )

    assert_received {:output, "production smoke: postgres passed"}
    assert_received {:output, "production smoke: redis passed"}
    assert_received {:output, "production smoke: complete"}
  end

  test "reports a failed check without including the underlying secret-bearing error" do
    error =
      assert_raise ProductionSmoke.Error, fn ->
        ProductionSmoke.run!(
          env: @env,
          checks: [
            {"redis",
             fn _config ->
               raise "failed redis://default:redis-password@redis.internal:6379"
             end}
          ],
          output: fn _line -> :ok end
        )
      end

    assert error.message == "production smoke check failed: redis"
    refute error.message =~ "redis-password"
    refute error.message =~ "redis://"
  end

  test "extracts the CSRF token and maintains the latest cookie values" do
    html = ~s(<input type="hidden" name="_csrf_token" value="csrf-value" />)

    assert Http.csrf_token!(html) == "csrf-value"

    cookies =
      Http.merge_cookies(%{"_event_sales_key" => "old"}, [
        {~c"set-cookie", ~c"_event_sales_key=new; path=/; secure; HttpOnly"},
        {~c"set-cookie", ~c"locale=en; path=/"}
      ])

    assert Http.cookie_header(cookies) in [
             "_event_sales_key=new; locale=en",
             "locale=en; _event_sales_key=new"
           ]
  end
end
