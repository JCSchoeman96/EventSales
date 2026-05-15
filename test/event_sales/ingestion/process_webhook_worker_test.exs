defmodule EventSales.Ingestion.ProcessWebhookWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    original = Application.get_env(:event_sales, :webhook_processor)

    on_exit(fn ->
      if original do
        Application.put_env(:event_sales, :webhook_processor, original)
      else
        Application.delete_env(:event_sales, :webhook_processor)
      end
    end)

    {:ok, source: source}
  end

  test "missing webhook_event_id is discarded safely" do
    assert :discard = perform(%{"webhook_event_id" => Ecto.UUID.generate()})
  end

  test "delegates processing decisions to the configured processor", %{source: source} do
    {:ok, event} = create_event(source)
    send_to = self()
    Application.put_env(:event_sales, :webhook_processor, __MODULE__.DelegateProcessor)
    __MODULE__.DelegateProcessor.set_parent(send_to)
    event_id = event.id

    assert :ok = perform(%{"webhook_event_id" => event.id})
    assert_receive {:processed_by_delegate, ^event_id}
  end

  test "transient processor failure returns a retryable error", %{source: source} do
    {:ok, event} = create_event(source)
    Application.put_env(:event_sales, :webhook_processor, __MODULE__.TransientProcessor)

    assert {:error, {:transient, :timeout}} = perform(%{"webhook_event_id" => event.id})
  end

  test "non-transient outcomes do not retry", %{source: source} do
    {:ok, event} = create_event(source)
    Application.put_env(:event_sales, :webhook_processor, __MODULE__.DiscardProcessor)

    assert :discard = perform(%{"webhook_event_id" => event.id})
  end

  test "backoff includes jitter" do
    job = %Oban.Job{attempt: 2}

    values =
      1..10
      |> Enum.map(fn _ -> ProcessWebhookWorker.backoff(job) end)
      |> Enum.uniq()

    assert Enum.all?(values, &(&1 >= 30))
    assert length(values) > 1
  end

  defp perform(args) do
    ProcessWebhookWorker.perform(%Oban.Job{args: args})
  end

  defp create_event(source) do
    now = DateTime.utc_now()

    WebhookEventStore.create_receive(%{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: "delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "hash-#{System.unique_integer([:positive])}",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: ~U[2026-05-01 08:05:00Z],
      sanitized_headers_snapshot: %{}
    })
  end

  defmodule DelegateProcessor do
    @moduledoc false

    def set_parent(pid), do: Process.put(:parent, pid)

    def process(webhook_event_id) do
      send(Process.get(:parent), {:processed_by_delegate, webhook_event_id})
      :ok
    end
  end

  defmodule TransientProcessor do
    @moduledoc false

    def process(_webhook_event_id), do: {:error, {:transient, :timeout}}
  end

  defmodule DiscardProcessor do
    @moduledoc false

    def process(_webhook_event_id), do: {:discard, :not_found}
  end
end
