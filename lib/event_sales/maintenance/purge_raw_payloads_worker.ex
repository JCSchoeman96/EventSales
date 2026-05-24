defmodule EventSales.Maintenance.PurgeRawPayloadsWorker do
  @moduledoc """
  Oban entrypoint for bounded raw webhook payload redaction.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 2,
    unique: [
      period: 300,
      fields: [:worker],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Maintenance.RawPayloadPurger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    case opts_from_args(args) do
      {:ok, opts} ->
        case purger().purge(opts) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp opts_from_args(args) do
    Enum.reduce_while(
      [{"retention_days", :retention_days}, {"batch_size", :batch_size}],
      {:ok, []},
      fn {arg_key, opt_key}, {:ok, opts} ->
        case Map.fetch(args, arg_key) do
          {:ok, value} when is_integer(value) and value > 0 ->
            {:cont, {:ok, [{opt_key, value} | opts]}}

          {:ok, _value} ->
            {:halt, :error}

          :error ->
            {:cont, {:ok, opts}}
        end
      end
    )
  end

  defp purger do
    Application.get_env(:event_sales, :maintenance_raw_payload_purger, RawPayloadPurger)
  end
end
