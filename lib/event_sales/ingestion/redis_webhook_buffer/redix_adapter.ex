defmodule EventSales.Ingestion.RedisWebhookBuffer.RedixAdapter do
  @moduledoc """
  Redis-backed webhook buffer using pending/processing lists and atomic push-when-not-full.
  """

  @behaviour EventSales.Ingestion.RedisWebhookBuffer.Adapter

  alias EventSales.Ingestion.RedisWebhookBuffer

  @push_script_path "priv/redis/push_when_not_full.lua"

  @impl true
  def push(entry) when is_binary(entry) do
    with {:ok, conn} <- connection(),
         {:ok, result} <-
           Redix.command(conn, [
             "EVAL",
             push_script_source(),
             1,
             pending_key(),
             max_entries(),
             entry
           ]) do
      case result do
        1 -> :ok
        0 -> {:error, :full}
        _ -> {:error, :unavailable}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  @impl true
  def claim do
    with {:ok, conn} <- connection(),
         {:ok, entry} when is_binary(entry) <-
           Redix.command(conn, ["LMOVE", pending_key(), processing_key(), "RIGHT", "LEFT"]) do
      {:ok, entry}
    else
      {:ok, nil} -> :empty
      _ -> :empty
    end
  end

  @impl true
  def ack(entry) when is_binary(entry) do
    with {:ok, conn} <- connection() do
      _ = Redix.command(conn, ["LREM", processing_key(), 1, entry])
      :ok
    else
      _ -> :ok
    end
  end

  @impl true
  def requeue(entry) when is_binary(entry) do
    with {:ok, conn} <- connection(),
         {:ok, pending_len} <- Redix.command(conn, ["LLEN", pending_key()]),
         {:ok, removed} <- Redix.command(conn, ["LREM", processing_key(), 1, entry]) do
      cond do
        removed == 0 ->
          {:error, :unavailable}

        pending_len >= max_entries() ->
          {:error, :full}

        true ->
          case Redix.command(conn, ["RPUSH", pending_key(), entry]) do
            {:ok, _} -> :ok
            _ -> {:error, :unavailable}
          end
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  @impl true
  def depth do
    with {:ok, conn} <- connection(),
         {:ok, len} <- Redix.command(conn, ["LLEN", pending_key()]) do
      len
    else
      _ -> 0
    end
  end

  @impl true
  def processing_depth do
    with {:ok, conn} <- connection(),
         {:ok, len} <- Redix.command(conn, ["LLEN", processing_key()]) do
      len
    else
      _ -> 0
    end
  end

  defp connection do
    case RedisWebhookBuffer.redix_name() |> Process.whereis() do
      nil -> {:error, :no_connection}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp push_script_source do
    Application.app_dir(:event_sales, @push_script_path)
    |> File.read!()
  end

  defp pending_key, do: RedisWebhookBuffer.key("pending")
  defp processing_key, do: RedisWebhookBuffer.key("processing")
  defp max_entries, do: RedisWebhookBuffer.max_entries()
end
