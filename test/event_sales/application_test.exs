defmodule EventSales.ApplicationTest do
  use ExUnit.Case, async: true

  test "repo is supervised in test" do
    assert Process.whereis(EventSales.Repo)
  end
end
