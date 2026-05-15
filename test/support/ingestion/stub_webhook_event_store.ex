defmodule EventSales.TestSupport.Ingestion.StubWebhookEventStore do
  @moduledoc """
  Test-only `WebhookEventStore` that can inject persist errors via the caller process.
  """

  alias EventSales.Ingestion.WebhookEventStore.Default

  @process_key :stub_webhook_event_store_error

  @spec set_persist_error(term()) :: :ok
  def set_persist_error(error) do
    Process.put(@process_key, error)
    :ok
  end

  @spec clear!() :: :ok
  def clear! do
    Process.delete(@process_key)
    :ok
  end

  @spec create_receive(map()) :: {:ok, struct()} | {:error, term()}
  def create_receive(attrs) do
    case Process.get(@process_key) do
      nil -> Default.create_receive(attrs)
      error -> {:error, error}
    end
  end
end
