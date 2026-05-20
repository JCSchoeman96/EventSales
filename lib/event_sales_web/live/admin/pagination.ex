defmodule EventSalesWeb.Live.Admin.Pagination do
  @moduledoc false

  def empty_page do
    %{page: 1, per_page: 25, has_next?: false, has_previous?: false}
  end
end
