defmodule EventSales.ApplicationTest do
  use ExUnit.Case, async: true

  test "repo is not supervised in test" do
    refute Process.whereis(EventSales.Repo)
  end
end
