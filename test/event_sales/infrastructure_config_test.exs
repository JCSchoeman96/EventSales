defmodule EventSales.InfrastructureConfigTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.CacheKeys
  alias EventSales.Ingestion.RedisWebhookBuffer
  alias EventSales.Repo

  @test_config_path Path.expand("../../config/test.exs", __DIR__)
  @dev_config_path Path.expand("../../config/dev.exs", __DIR__)
  @repository_root Path.expand("../..", __DIR__)
  @managed_env_keys [
    "EVENTSALES_CI_EPHEMERAL_PG",
    "EVENTSALES_DEV_DATABASE_USERNAME",
    "GITHUB_ACTIONS",
    "MIX_TEST_PARTITION",
    "TEST_DATABASE_HOST",
    "TEST_DATABASE_NAME",
    "TEST_DATABASE_PASSWORD",
    "TEST_DATABASE_PORT",
    "TEST_DATABASE_POOL_SIZE",
    "TEST_DATABASE_USERNAME",
    "DATABASE_URL"
  ]

  test "DEV and TEST repository configurations target different locked clusters" do
    dev_repo = read_repo_config(@dev_config_path, :dev)
    test_repo = Repo.config()

    assert dev_repo[:hostname] == "127.0.0.1"
    assert dev_repo[:port] == 55_432
    assert dev_repo[:database] == "event_sales_dev"
    assert dev_repo[:username] == "eventsales_dev"

    assert test_repo[:hostname] == "127.0.0.1"

    assert {test_repo[:hostname], test_repo[:port]} == {"127.0.0.1", 55_433}
    assert test_repo[:username] == "eventsales_test"
    assert String.starts_with?(test_repo[:database], "event_sales_test")
    refute test_repo[:database] == "event_sales_dev"
    refute Keyword.has_key?(test_repo, :url)
    assert Repo.min_pg_version() == Version.parse!("18.0.0")
  end

  test "TEST Repo uses a bounded shared-server connection pool by default" do
    test_repo = read_repo_config(@test_config_path, :test)
    assert test_repo[:pool_size] == 10
  end

  test "TEST configuration rejects a local caller's CI port override" do
    assert_raise RuntimeError, ~r/TEST PostgreSQL endpoint/, fn ->
      read_repo_config(@test_config_path, :test, %{
        "GITHUB_ACTIONS" => "false",
        "TEST_DATABASE_HOST" => "127.0.0.1",
        "TEST_DATABASE_PORT" => "5432",
        "TEST_DATABASE_USERNAME" => "eventsales_test",
        "TEST_DATABASE_PASSWORD" => "test-only",
        "TEST_DATABASE_NAME" => "event_sales_test"
      })
    end
  end

  test "CI uses the same locked TEST endpoint on its job-owned service" do
    repo_config =
      read_repo_config(@test_config_path, :test, %{
        "GITHUB_ACTIONS" => "true",
        "EVENTSALES_CI_EPHEMERAL_PG" => "true",
        "TEST_DATABASE_HOST" => "127.0.0.1",
        "TEST_DATABASE_PORT" => "55433",
        "TEST_DATABASE_USERNAME" => "eventsales_test",
        "TEST_DATABASE_PASSWORD" => "",
        "TEST_DATABASE_NAME" => "event_sales_test"
      })

    assert repo_config[:port] == 55_433
    assert repo_config[:hostname] == "127.0.0.1"
    assert repo_config[:username] == "eventsales_test"
  end

  test "a spoofed GitHub Actions environment cannot permit local port 5432" do
    assert_raise RuntimeError, ~r/TEST PostgreSQL endpoint/, fn ->
      read_repo_config(@test_config_path, :test, %{
        "GITHUB_ACTIONS" => "true",
        "EVENTSALES_CI_EPHEMERAL_PG" => "true",
        "TEST_DATABASE_HOST" => "127.0.0.1",
        "TEST_DATABASE_PORT" => "5432",
        "TEST_DATABASE_USERNAME" => "eventsales_test",
        "TEST_DATABASE_PASSWORD" => "test-only",
        "TEST_DATABASE_NAME" => "event_sales_test"
      })
    end
  end

  test "TEST configuration rejects the DEV role" do
    assert_raise RuntimeError, ~r/eventsales_test role/, fn ->
      read_repo_config(@test_config_path, :test, %{
        "GITHUB_ACTIONS" => "false",
        "TEST_DATABASE_HOST" => "127.0.0.1",
        "TEST_DATABASE_PORT" => "55433",
        "TEST_DATABASE_USERNAME" => "eventsales_dev",
        "TEST_DATABASE_PASSWORD" => "dev-only",
        "TEST_DATABASE_NAME" => "event_sales_test"
      })
    end
  end

  test "TEST configuration rejects the PostgreSQL DEV port" do
    assert_raise RuntimeError, ~r/TEST PostgreSQL endpoint/, fn ->
      read_repo_config(@test_config_path, :test, %{
        "TEST_DATABASE_HOST" => "127.0.0.1",
        "TEST_DATABASE_PORT" => "55432",
        "TEST_DATABASE_USERNAME" => "eventsales_test",
        "TEST_DATABASE_PASSWORD" => "test-only",
        "TEST_DATABASE_NAME" => "event_sales_test",
        "DATABASE_URL" => "ecto://eventsales_dev:ignored@127.0.0.1:55432/event_sales_dev"
      })
    end
  end

  test "TEST partition suffix is appended to the supplied TEST database name" do
    repo_config =
      read_repo_config(@test_config_path, :test, %{
        "EVENTSALES_CI_EPHEMERAL_PG" => "false",
        "TEST_DATABASE_HOST" => "127.0.0.1",
        "TEST_DATABASE_PORT" => "55433",
        "TEST_DATABASE_USERNAME" => "eventsales_test",
        "TEST_DATABASE_PASSWORD" => "test-only",
        "TEST_DATABASE_NAME" => "event_sales_test",
        "MIX_TEST_PARTITION" => "2"
      })

    assert repo_config[:database] == "event_sales_test2"
  end

  test "Redis keys include both the EventSales project and environment namespaces" do
    assert Application.get_env(:event_sales, :redis_namespace) == "eventsales:test"

    assert CacheKeys.redis_event_snapshot("event-id") ==
             "eventsales:test:analytics:hot_state:v1:event:event-id:summary"

    assert RedisWebhookBuffer.key("pending") == "eventsales:test:webhook_buffer:v1:pending"

    rate_limit = Application.get_env(:event_sales, :webhook_intake_rate_limit, [])
    assert Keyword.fetch!(rate_limit, :key_prefix) == "eventsales:test:webhook_rate_limit:v1"
  end

  test "canonical Compose deploys only the app and leaves databases and Redis external" do
    compose = read_repo_file!("compose.yaml")

    assert compose =~ "services:\n  app:"
    assert compose =~ "EVENTSALES_DEPLOY_ENV_FILE"
    assert compose =~ "env_file:"
    refute compose =~ ~r/^  (postgres|redis):/m
    refute compose =~ "container_name:"
    refute compose =~ "volumes:"

    refute compose =~
             ~r/\b(?:DATABASE_URL|DIRECT_DATABASE_URL|REDIS_URL|SECRET_KEY_BASE):\s*\$\{/m

    refute compose =~ "5432:5432"
    refute compose =~ "6379:6379"
  end

  test "legacy database reset cannot delete the preserved development volume" do
    legacy_script = read_repo_file!("scripts/dev_postgres.sh")
    mix_aliases = read_repo_file!("mix.exs")

    assert legacy_script =~ "Legacy database reset is disabled"
    assert legacy_script =~ "Legacy container creation is disabled"
    refute legacy_script =~ "docker volume rm"
    refute legacy_script =~ "docker rm -f"
    refute legacy_script =~ "docker run"
    refute mix_aliases =~ "ecto.reset"
  end

  test "CI uses PostgreSQL 18 with job-owned non-superuser TEST roles and no fixed password" do
    workflow = read_repo_file!(".github/workflows/ci.yml")

    assert workflow =~ "image: postgres:18-alpine"
    assert workflow =~ "CREATE ROLE eventsales_test WITH LOGIN CREATEDB"
    assert workflow =~ "TEST_DATABASE_PORT: \"55433\""
    assert workflow =~ "- 55433:5432"
    refute workflow =~ "POSTGRES_PASSWORD:"
    refute workflow =~ "TEST_DATABASE_PASSWORD:"
    refute workflow =~ "ci-eventsales-test"
  end

  test "shared Redis adapters do not issue global flush commands" do
    redis_sources =
      [
        "lib/event_sales/ingestion/redis_rate_limiter/redix_adapter.ex",
        "lib/event_sales/ingestion/redis_webhook_buffer/redix_adapter.ex",
        "lib/event_sales/analytics/snapshot_store/redix_adapter.ex"
      ]
      |> Enum.map_join("\n", &read_repo_file!/1)

    refute redis_sources =~ ~r/\bFLUSH(?:ALL|DB)\b/i
  end

  defp read_repo_config(path, env, overrides \\ %{}) do
    original = Map.new(@managed_env_keys, &{&1, System.get_env(&1)})
    Enum.each(@managed_env_keys, &System.delete_env/1)

    Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)

    try do
      path
      |> Config.Reader.read!(env: env)
      |> Keyword.get(:event_sales, [])
      |> Keyword.fetch!(Repo)
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp read_repo_file!(relative_path), do: File.read!(Path.join(@repository_root, relative_path))
end
