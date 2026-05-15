defmodule EventSales.Ingestion.RedisWebhookBufferTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.RedisWebhookBuffer
  alias EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter

  setup do
    MemoryWebhookBufferAdapter.reset!()
    on_exit(fn -> MemoryWebhookBufferAdapter.reset!() end)
    :ok
  end

  test "push at capacity returns full without evicting existing entries" do
    assert :ok = RedisWebhookBuffer.push(%{"v" => 1, "n" => 1})
    assert :ok = RedisWebhookBuffer.push(%{"v" => 1, "n" => 2})
    assert :ok = RedisWebhookBuffer.push(%{"v" => 1, "n" => 3})
    assert {:error, :full} = RedisWebhookBuffer.push(%{"v" => 1, "n" => 4})
    assert RedisWebhookBuffer.depth() == 3
  end

  test "push rejects entries over max_entry_bytes" do
    huge = %{data: String.duplicate("x", RedisWebhookBuffer.max_entry_bytes() + 1)}
    assert {:error, :too_large} = RedisWebhookBuffer.push(huge)
  end

  test "claim moves entry to processing and ack clears it" do
    encoded = "buffer-entry-1"

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    assert RedisWebhookBuffer.depth() == 1
    assert {:ok, ^encoded} = RedisWebhookBuffer.claim()
    assert RedisWebhookBuffer.depth() == 0
    assert RedisWebhookBuffer.processing_depth() == 1
    assert :ok = RedisWebhookBuffer.ack(encoded)
    assert RedisWebhookBuffer.processing_depth() == 0
  end

  test "requeue returns entry to pending when room" do
    encoded = "buffer-entry-2"

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    assert {:ok, ^encoded} = RedisWebhookBuffer.claim()
    assert :ok = RedisWebhookBuffer.requeue(encoded)
    assert RedisWebhookBuffer.depth() == 1
    assert RedisWebhookBuffer.processing_depth() == 0
  end
end
