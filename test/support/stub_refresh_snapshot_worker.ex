defmodule EventSales.TestSupport.StubRefreshSnapshotWorker do
  @moduledoc false

  def enqueue_event(_event_id, _opts), do: :ok
  def enqueue_events(_event_ids, _opts), do: :ok
end
