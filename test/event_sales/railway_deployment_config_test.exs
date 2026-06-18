defmodule EventSales.RailwayDeploymentConfigTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "Dockerfile builds a production OTP release and runs as a non-root user" do
    dockerfile = read!("Dockerfile")

    assert dockerfile =~ "ARG ELIXIR_VERSION=1.19.3"
    assert dockerfile =~ "ARG OTP_VERSION=28.1.1"
    assert dockerfile =~ "MIX_ENV=prod"
    assert dockerfile =~ "mix assets.deploy"
    assert dockerfile =~ "mix release"
    assert dockerfile =~ "USER eventsales"
    assert dockerfile =~ ~s(CMD ["bin/event_sales", "start"])
    refute dockerfile =~ "SECRET_KEY_BASE="
    refute dockerfile =~ "DATABASE_URL="
  end

  test "Docker context excludes local state and secrets" do
    dockerignore = read!(".dockerignore")

    for entry <- ["_build", "deps", ".git", ".env", ".worktrees"] do
      assert dockerignore =~ entry
    end
  end

  test "Railway config uses Docker, release initialization, health gating, and bounded restart" do
    railway = read!("railway.toml")

    assert railway =~ ~s(builder = "DOCKERFILE")
    assert railway =~ ~s(dockerfilePath = "Dockerfile")

    assert railway =~
             ~S|preDeployCommand = "bin/event_sales eval 'EventSales.Release.migrate_and_bootstrap()'"|

    assert railway =~ ~s(startCommand = "bin/event_sales start")
    assert railway =~ ~s(healthcheckPath = "/health")
    assert railway =~ "healthcheckTimeout = 300"
    assert railway =~ ~s(restartPolicyType = "ON_FAILURE")
    assert railway =~ "restartPolicyMaxRetries = 10"
  end

  test "Railway smoke wrapper runs inside the release without placing secrets on the command line" do
    script = read!("scripts/smoke_test_railway_release.sh")

    assert script =~ "set -euo pipefail"
    assert script =~ "railway ssh"
    assert script =~ "env -u PHX_SERVER"
    assert script =~ "EventSales.Maintenance.ProductionSmoke.run!()"

    for secret_name <- [
          "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD",
          "WOOCOMMERCE_WEBHOOK_SECRET",
          "SECRET_KEY_BASE",
          "DATABASE_URL",
          "REDIS_URL"
        ] do
      refute script =~ "${#{secret_name}}"
    end
  end

  defp read!(path), do: File.read!(Path.join(@root, path))
end
