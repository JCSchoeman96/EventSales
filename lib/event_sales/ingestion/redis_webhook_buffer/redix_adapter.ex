defmodule EventSales.Ingestion.RedisWebhookBuffer.RedixAdapter do
  @moduledoc """
  Redis-backed webhook buffer using pending/processing lists and atomic push-when-not-full.
  """

  @behaviour EventSales.Ingestion.RedisWebhookBuffer.Adapter

  alias EventSales.Ingestion.RedisWebhookBuffer

  @push_script_path "priv/redis/push_when_not_full.lua"
  @requeue_script_path "priv/redis/requeue_when_room.lua"

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
      map_push_result(result)
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
    case connection() do
      {:ok, conn} ->
        case Redix.command(conn, ["LREM", processing_key(), 1, entry]) do
          {:ok, n} when n > 0 -> :ok
          {:ok, 0} -> {:error, :unavailable}
          _ -> {:error, :unavailable}
        end

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  @impl true
  def requeue(entry) when is_binary(entry) do
    with {:ok, conn} <- connection(),
         {:ok, result} <-
           Redix.command(conn, [
             "EVAL",
             requeue_script_source(),
             2,
             pending_key(),
             processing_key(),
             max_entries(),
             entry
           ]) do
      map_requeue_result(result)
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

  defp map_push_result(1), do: :ok
  defp map_push_result(0), do: {:error, :full}
  defp map_push_result(_), do: {:error, :unavailable}

  defp map_requeue_result(1), do: :ok
  defp map_requeue_result(0), do: {:error, :full}
  defp map_requeue_result(-1), do: {:error, :unavailable}
  defp map_requeue_result(_), do: {:error, :unavailable}

  defp connection do
    case RedisWebhookBuffer.redix_name() |> Process.whereis() do
      nil -> {:error, :no_connection}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp push_script_source do
    Application.app_dir(:event_sales, @push_script_path) |> File.read!()
  end

  defp requeue_script_source do
    Application.app_dir(:event_sales, @requeue_script_path) |> File.read!()
  end

  defp pending_key, do: RedisWebhookBuffer.key("pending")
  defp processing_key, do: RedisWebhookBuffer.key("processing")
  defp max_entries, do: RedisWebhookBuffer.max_entries()
end
