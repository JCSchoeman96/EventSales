defmodule EventSales.Maintenance.CutoverDryRunTest do
  use ExUnit.Case, async: true

  alias EventSales.Maintenance.CutoverDryRun

  test "rollback runbook exists in repository checkout" do
    path = Path.join(File.cwd!(), "docs/runbooks/live-webhook-cutover.md")

    assert File.exists?(path)
    assert File.read!(path) =~ "Rollback"
  end

  test "cutover dry run module is available" do
    assert Code.ensure_loaded?(CutoverDryRun)
    assert function_exported?(CutoverDryRun, :run!, 0)
  end
end
