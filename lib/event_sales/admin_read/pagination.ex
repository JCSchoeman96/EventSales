defmodule EventSales.AdminRead.Pagination do
  @moduledoc false

  def pagination(opts, default_per_page, max_per_page) do
    page =
      opts
      |> Keyword.get(:page, 1)
      |> normalize_positive_integer(1)

    per_page =
      opts
      |> Keyword.get(:per_page, default_per_page)
      |> normalize_positive_integer(default_per_page)
      |> min(max_per_page)

    %{page: page, per_page: per_page, offset: (page - 1) * per_page}
  end

  def normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  def normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  def normalize_positive_integer(_value, default), do: default

  def split_page(rows, per_page) do
    visible_rows = Enum.take(rows, per_page)
    {visible_rows, length(rows) > per_page}
  end

  def page_info(page, per_page, has_next?) do
    %{
      page: page,
      per_page: per_page,
      has_next?: has_next?,
      has_previous?: page > 1
    }
  end
end
