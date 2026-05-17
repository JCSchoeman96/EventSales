defmodule EventSales.TestSupport.Analytics.SelectiveEventAggregator do
  @moduledoc false

  alias EventSales.Analytics.Aggregators.EventAggregator

  @key {__MODULE__, :failures}

  def fail_event!(event_id, reason) do
    failures = :persistent_term.get(@key, %{})
    :persistent_term.put(@key, Map.put(failures, event_id, reason))
    :ok
  end

  def reset! do
    :persistent_term.put(@key, %{})
    :ok
  end

  def summary_for_event(event_id, opts \\ []) do
    case Map.fetch(:persistent_term.get(@key, %{}), event_id) do
      {:ok, reason} -> {:error, reason}
      :error -> EventAggregator.summary_for_event(event_id, opts)
    end
  end
end
