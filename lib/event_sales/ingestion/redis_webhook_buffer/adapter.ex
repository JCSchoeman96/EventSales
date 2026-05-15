defmodule EventSales.Ingestion.RedisWebhookBuffer.Adapter do
  @moduledoc """
  Behaviour for bounded webhook buffer storage (Redis or in-memory).
  """

  @type encoded_entry :: binary()
  @type push_error :: :full | :disabled | :unavailable
  @type requeue_error :: :full | :unavailable

  @callback push(encoded_entry()) :: :ok | {:error, push_error()}
  @callback claim() :: {:ok, encoded_entry()} | :empty
  @callback ack(encoded_entry()) :: :ok
  @callback requeue(encoded_entry()) :: :ok | {:error, requeue_error()}
  @callback depth() :: non_neg_integer()
  @callback processing_depth() :: non_neg_integer()
end
