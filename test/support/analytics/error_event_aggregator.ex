defmodule EventSales.TestSupport.Analytics.ErrorEventAggregator do
  @moduledoc false

  def summary_for_event(_event_id, _opts \\ []) do
    {:error, :db_unavailable}
  end
end
