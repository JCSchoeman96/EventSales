defmodule EventSales.Maintenance.PrivateRuntimeSmokeTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.RedisRateLimiter.RedixAdapter
  alias EventSales.Maintenance.PrivateRuntimeSmoke

  @database_url "ecto://runtime-user:synthetic-runtime-password@pgbouncer:6432/event_sales_prod"
  @forbidden_environment_keys [
    "DIRECT_DATABASE_URL",
    "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL",
    "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD",
    "EVENTSALES_BOOTSTRAP_ADMIN_NAME",
    "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD",
    "EVENTSALES_BOOTSTRAP_SOURCE_NAME",
    "EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL"
  ]

  setup do
    config_keys = [
      :redis_namespace,
      Oban,
      :webhook_intake_rate_limit,
      :redis_webhook_buffer,
      :hot_state_aggregator
    ]

    previous_config =
      Map.new(config_keys, fn key -> {key, Application.fetch_env(:event_sales, key)} end)

    Application.put_env(:event_sales, :redis_namespace, "eventsales:prod")

    Application.put_env(
      :event_sales,
      Oban,
      Application.get_env(:event_sales, Oban, [])
      |> Keyword.put(:notifier, Oban.Notifiers.PG)
    )

    Application.put_env(:event_sales, :webhook_intake_rate_limit,
      enabled: true,
      adapter: RedixAdapter,
      key_prefix: "eventsales:prod:webhook_rate_limit:v1"
    )

    Application.put_env(:event_sales, :redis_webhook_buffer,
      enabled: false,
      durability_accepted: false
    )

    Application.put_env(:event_sales, :hot_state_aggregator,
      redis_enabled: false,
      snapshot_adapter: EventSales.Analytics.SnapshotStore.NoopAdapter
    )

    on_exit(fn ->
      Enum.each(previous_config, fn
        {key, {:ok, value}} -> Application.put_env(:event_sales, key, value)
        {key, :error} -> Application.delete_env(:event_sales, key)
      end)
    end)

    :ok
  end

  test "accepts the private PgBouncer target and returns only safe structure" do
    config =
      PrivateRuntimeSmoke.config!(%{
        "DATABASE_URL" => @database_url,
        "REDIS_URL" => "redis://runtime-user:synthetic-redis-password@redis:6379/0",
        "RELEASE_COOKIE" => "synthetic-release-cookie"
      })

    assert config == %{
             database_host: "pgbouncer",
             database_port: 6432,
             database_name: "event_sales_prod",
             hot_state_redis_enabled?: false,
             timeout_ms: 60_000,
             poll_interval_ms: 500
           }

    refute inspect(config) =~ @database_url
    refute inspect(config) =~ "synthetic-runtime-password"
    refute inspect(config) =~ "synthetic-redis-password"
    refute inspect(config) =~ "synthetic-release-cookie"
  end

  test "rejects direct migration and bootstrap-only environment variables safely" do
    Enum.each(@forbidden_environment_keys, fn key ->
      secret_value = "synthetic-forbidden-value"

      error =
        assert_raise PrivateRuntimeSmoke.Error, fn ->
          PrivateRuntimeSmoke.config!(%{
            "DATABASE_URL" => @database_url,
            key => secret_value
          })
        end

      assert error.message =~ key
      refute error.message =~ secret_value
    end)
  end

  test "rejects a database URL that does not match the D1 PgBouncer target" do
    invalid_urls = [
      "ecto://runtime-user:synthetic-password@postgres:6432/event_sales_prod",
      "ecto://runtime-user:synthetic-password@pgbouncer:5432/event_sales_prod",
      "ecto://runtime-user:synthetic-password@pgbouncer:6432/event_sales_other",
      "not-a-database-url"
    ]

    Enum.each(invalid_urls, fn url ->
      error =
        assert_raise PrivateRuntimeSmoke.Error, fn ->
          PrivateRuntimeSmoke.config!(%{"DATABASE_URL" => url})
        end

      refute error.message =~ "synthetic-password"
      refute error.message =~ url
    end)
  end

  test "requires the D1 Redis namespace" do
    Application.put_env(:event_sales, :redis_namespace, "eventsales:test")
    assert_config_rejected()
  end

  test "requires Oban PG notifications" do
    Application.put_env(
      :event_sales,
      Oban,
      Application.get_env(:event_sales, Oban, [])
      |> Keyword.put(:notifier, Oban.Notifiers.Postgres)
    )

    assert_config_rejected()
  end

  test "requires webhook degraded buffering and durability acceptance to remain false" do
    for buffer_config <- [
          [enabled: true, durability_accepted: false],
          [enabled: false, durability_accepted: true]
        ] do
      Application.put_env(:event_sales, :redis_webhook_buffer, buffer_config)
      assert_config_rejected()
    end
  end

  test "requires the real namespaced Redis rate limiter adapter" do
    Application.put_env(:event_sales, :webhook_intake_rate_limit,
      enabled: true,
      adapter: RedixAdapter,
      key_prefix: "eventsales:test:webhook_rate_limit:v1"
    )

    assert_config_rejected()
  end

  test "runs named checks in order and emits only safe labels" do
    caller = self()

    assert :ok =
             PrivateRuntimeSmoke.run!(
               env: %{"DATABASE_URL" => @database_url},
               checks: [
                 {"application",
                  fn _config ->
                    send(caller, :application_checked)
                    :ok
                  end},
                 {"migrations",
                  fn _config ->
                    assert_received :application_checked
                    :ok
                  end}
               ],
               output: fn line -> send(caller, {:output, line}) end
             )

    assert_received {:output, "private runtime smoke: application passed"}
    assert_received {:output, "private runtime smoke: migrations passed"}
    assert_received {:output, "private runtime smoke: complete"}
  end

  test "surfaces only the fixed check label when a check raises with a secret" do
    secret = "synthetic-check-secret-82ad"

    error =
      assert_raise PrivateRuntimeSmoke.Error, fn ->
        PrivateRuntimeSmoke.run!(
          env: %{"DATABASE_URL" => @database_url},
          checks: [
            {"database identity", fn _config -> raise "connection failed password=#{secret}" end}
          ],
          output: fn _line -> :ok end
        )
      end

    assert error.message == "private runtime smoke check failed: database identity"
    refute error.message =~ secret
  end

  defp assert_config_rejected do
    error =
      assert_raise PrivateRuntimeSmoke.Error, fn ->
        PrivateRuntimeSmoke.config!(%{"DATABASE_URL" => @database_url})
      end

    refute error.message =~ @database_url
  end
end
