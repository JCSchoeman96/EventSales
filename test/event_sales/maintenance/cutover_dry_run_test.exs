defmodule EventSales.Maintenance.CutoverDryRunTest do
  use ExUnit.Case, async: true

  alias EventSales.Maintenance.CutoverDryRun

  @env %{
    "RAILWAY_PUBLIC_DOMAIN" => "eventsales-production.up.railway.app",
    "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL" => "admin@example.test",
    "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD" => "Admin-Password-123!",
    "WEBHOOK_PATH_TOKEN" => "path-token",
    "WOOCOMMERCE_WEBHOOK_SECRET" => "webhook-secret"
  }

  test "rollback runbook exists in repository checkout" do
    path = Path.join(File.cwd!(), "docs/runbooks/live-webhook-cutover.md")

    assert File.exists?(path)
    assert File.read!(path) =~ "Rollback"
  end

  test "cutover dry run module is available" do
    assert Code.ensure_loaded?(CutoverDryRun)
    assert function_exported?(CutoverDryRun, :run!, 0)
  end

  test "default checks start application startup before HTTP-dependent checks" do
    assert CutoverDryRun.default_check_labels() == [
             "application",
             "woocommerce rest configuration",
             "rollback runbook present",
             "synthetic webhook intake only",
             "admin reconciliation surfaces",
             "oban webhooks queue execution"
           ]
  end

  test "run! executes application check before HTTP-dependent checks" do
    caller = self()

    assert :ok =
             CutoverDryRun.run!(
               env: @env,
               checks: [
                 {"application",
                  fn _config ->
                    send(caller, :application)
                    :ok
                  end},
                 {"synthetic webhook intake only",
                  fn _config ->
                    assert_received :application
                    :ok
                  end}
               ],
               output: fn _line -> :ok end
             )
  end
end
