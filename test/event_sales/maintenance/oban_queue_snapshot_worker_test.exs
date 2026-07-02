defmodule EventSales.Maintenance.ObanQueueSnapshotWorkerTest do
  use EventSales.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias EventSales.Maintenance.ObanQueueSnapshotWorker
  alias EventSales.Repo
  alias EventSales.Telemetry

  setup do
    Repo.delete_all(from(j in Oban.Job))

    original = Application.get_env(:event_sales, :maintenance)

    Application.put_env(:event_sales, :maintenance, webhook_queue_backlog_threshold: 0)

    on_exit(fn ->
      Repo.delete_all(from(j in Oban.Job))

      case original do
        nil -> Application.delete_env(:event_sales, :maintenance)
        value -> Application.put_env(:event_sales, :maintenance, value)
      end
    end)

    :ok
  end

  test "uses maintenance queue and does not retry" do
    assert ObanQueueSnapshotWorker.__opts__() |> Keyword.fetch!(:queue) == :maintenance
    assert ObanQueueSnapshotWorker.__opts__() |> Keyword.fetch!(:max_attempts) == 1
  end

  test "emits grouped queue snapshots and warns when webhook backlog exceeds threshold" do
    _webhook_job = insert_job!("webhooks", "available")
    _reconciliation_job = insert_job!("reconciliation", "scheduled")

    handler_id = "oban-queue-snapshot-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.oban_queue_snapshot(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = ObanQueueSnapshotWorker.perform(%Oban.Job{args: %{}})
      end)

    assert log =~ "oban_webhook_queue_backlog"

    assert_receive {:telemetry, [:event_sales, :oban, :queue_snapshot], %{count: 1},
                    %{queue: "webhooks", state: "available"}},
                   500

    assert_receive {:telemetry, [:event_sales, :oban, :queue_snapshot], %{count: 1},
                    %{queue: "reconciliation", state: "scheduled"}},
                   500

    assert_receive {:telemetry, [:event_sales, :oban, :queue_snapshot], %{count: _groups},
                    %{worker: :oban_queue_snapshot_worker, reason: :threshold_exceeded}},
                   500
  end

  defp insert_job!(queue, state) do
    now = DateTime.utc_now()

    Repo.insert!(%Oban.Job{
      args: %{"kind" => "snapshot-test"},
      worker: "EventSales.TestWorker",
      queue: queue,
      state: state,
      attempt: 0,
      max_attempts: 3,
      inserted_at: now,
      scheduled_at: now,
      priority: 0,
      errors: [],
      tags: [],
      meta: %{}
    })
  end
end
