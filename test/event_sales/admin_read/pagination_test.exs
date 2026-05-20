defmodule EventSales.AdminRead.PaginationTest do
  use ExUnit.Case, async: true

  alias EventSales.AdminRead.Pagination

  @default_per_page 25
  @max_per_page 50

  describe "pagination/3" do
    test "defaults page and per_page" do
      assert %{page: 1, per_page: 25, offset: 0} =
               Pagination.pagination([], @default_per_page, @max_per_page)
    end

    test "invalid page string falls back to 1" do
      assert %{page: 1, per_page: 25, offset: 0} =
               Pagination.pagination([page: "abc"], @default_per_page, @max_per_page)
    end

    test "negative page falls back to 1" do
      assert %{page: 1, per_page: 25, offset: 0} =
               Pagination.pagination([page: -3], @default_per_page, @max_per_page)
    end

    test "valid page string is parsed" do
      assert %{page: 2, per_page: 25, offset: 25} =
               Pagination.pagination([page: "2"], @default_per_page, @max_per_page)
    end

    test "oversized per_page is capped at max" do
      assert %{page: 1, per_page: 50, offset: 0} =
               Pagination.pagination([per_page: 999], @default_per_page, @max_per_page)
    end

    test "invalid per_page string falls back to default" do
      assert %{page: 1, per_page: 25, offset: 0} =
               Pagination.pagination([per_page: "nope"], @default_per_page, @max_per_page)
    end
  end

  describe "normalize_positive_integer/2" do
    test "returns default for zero and negative integers" do
      assert Pagination.normalize_positive_integer(0, 7) == 7
      assert Pagination.normalize_positive_integer(-1, 7) == 7
    end

    test "returns default for partial integer strings" do
      assert Pagination.normalize_positive_integer("12abc", 7) == 7
    end
  end

  describe "page_info/3" do
    test "page 1 has no previous page" do
      assert %{page: 1, per_page: 25, has_next?: true, has_previous?: false} =
               Pagination.page_info(1, 25, true)
    end

    test "page 2 has previous page" do
      assert %{page: 2, per_page: 25, has_next?: false, has_previous?: true} =
               Pagination.page_info(2, 25, false)
    end
  end

  describe "split_page/2" do
    test "lookahead: extra row signals has_next?" do
      rows = Enum.to_list(1..26)

      assert {visible, true} = Pagination.split_page(rows, 25)
      assert length(visible) == 25
      assert visible == Enum.to_list(1..25)
    end

    test "no extra row means no next page" do
      rows = Enum.to_list(1..25)

      assert {visible, false} = Pagination.split_page(rows, 25)
      assert length(visible) == 25
    end
  end
end
