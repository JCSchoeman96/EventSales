defmodule EventSales.LaunchCertificationTest do
  use ExUnit.Case, async: false

  @moduletag :launch_certification

  alias EventSales.Telemetry

  @required_runbooks %{
    "docs/runbooks/live-webhook-cutover.md" => "Rollback",
    "docs/runbooks/event-launch-checklist.md" => "Cutover",
    "docs/runbooks/reconciliation.md" => "Operator",
    "docs/runbooks/mapping-review.md" => "Pre-launch",
    "docs/runbooks/oban-queue-backlog.md" => "Thresholds",
    "docs/runbooks/database-backup-restore.md" => "Restore"
  }

  test "webhook HTTP rate limiter is configured and wired" do
    router = File.read!("lib/event_sales_web/router.ex")
    endpoint = File.read!("lib/event_sales_web/endpoint.ex")

    assert router =~ "RateLimitWebhookIntake"
    assert endpoint =~ "WebhookIntakePreParserGuard"

    config = Application.get_env(:event_sales, :webhook_intake_rate_limit, [])
    assert Keyword.get(config, :enabled, true)
    assert is_integer(Keyword.get(config, :max_requests))
  end

  test "REST max concurrency remains 2" do
    config = File.read!("config/config.exs")
    runtime = File.read!("config/runtime.exs")

    assert config =~ "max_concurrency: 2"
    assert runtime =~ "max_concurrency: 2"
  end

  test "web layer does not reference WooCommerce REST client" do
    {output, 0} =
      System.cmd("bash", ["scripts/check_no_web_woocommerce_refs.sh"],
        cd: File.cwd!(),
        env: [{"LC_ALL", "C.UTF-8"}]
      )

    assert output =~ "No forbidden WooCommerce REST references found"
  end

  test "queue snapshot telemetry event exists" do
    assert Telemetry.oban_queue_snapshot() in Telemetry.event_names()
  end

  test "required operator runbooks exist with expected sections" do
    for {path, marker} <- @required_runbooks do
      assert File.exists?(path), "missing runbook #{path}"
      assert File.read!(path) =~ marker
    end
  end

  test "cutover and backup scripts exist" do
    assert File.exists?("scripts/cutover_dry_run.sh")
    assert File.exists?("scripts/verify_backup_restore.sh")
    assert File.exists?("scripts/smoke_test_webhook_signature.exs")
  end
end
