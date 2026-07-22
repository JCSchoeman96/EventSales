defmodule EventSales.ApplicationTest do
  use ExUnit.Case, async: true

  test "repo is supervised in test" do
    assert Process.whereis(EventSales.Repo)
  end

  test "default database readiness probe is disabled under SQL Sandbox" do
    refute Process.whereis(EventSales.Health.DatabaseReadiness)
  end
end
