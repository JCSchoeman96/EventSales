defmodule EventSales.Maintenance.PurgeRawPayloadsWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Maintenance.PurgeRawPayloadsWorker

  test "uses maintenance queue and low attempts" do
    assert PurgeRawPayloadsWorker.__opts__() |> Keyword.fetch!(:queue) == :maintenance
    assert PurgeRawPayloadsWorker.__opts__() |> Keyword.fetch!(:max_attempts) == 2
  end

  test "discards invalid args" do
    assert :discard =
             PurgeRawPayloadsWorker.perform(%Oban.Job{
               args: %{"retention_days" => 0}
             })

    assert :discard =
             PurgeRawPayloadsWorker.perform(%Oban.Job{
               args: %{"batch_size" => -1}
             })
  end

  test "returns purge errors without emitting duplicate exception telemetry" do
    original = Application.get_env(:event_sales, :maintenance_raw_payload_purger)
    Application.put_env(:event_sales, :maintenance_raw_payload_purger, __MODULE__.FailingPurger)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:event_sales, :maintenance_raw_payload_purger)
        value -> Application.put_env(:event_sales, :maintenance_raw_payload_purger, value)
      end
    end)

    assert {:error, :boom} = PurgeRawPayloadsWorker.perform(%Oban.Job{args: %{}})

    refute_received {:telemetry, [:event_sales, :maintenance, :raw_payload_purge, :exception], _,
                     _}
  end

  defmodule FailingPurger do
    @moduledoc false
    def purge(_opts), do: {:error, :boom}
  end
end
