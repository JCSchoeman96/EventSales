defmodule EventSales.Maintenance.FailedJobAlertWorkerTest do
  use EventSales.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias EventSales.Maintenance.FailedJobAlertWorker
  alias EventSales.Repo
  alias EventSales.Telemetry

  setup do
    Repo.delete_all(from(j in Oban.Job))

    original = Application.get_env(:event_sales, :maintenance)

    Application.put_env(:event_sales, :maintenance,
      failed_job_alert_threshold: 1,
      failed_job_alert_stale_after_minutes: 15
    )

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
    assert FailedJobAlertWorker.__opts__() |> Keyword.fetch!(:queue) == :maintenance
    assert FailedJobAlertWorker.__opts__() |> Keyword.fetch!(:max_attempts) == 1
  end

  test "counts discarded jobs, logs, emits telemetry, and does not mutate jobs" do
    job = insert_job!("discarded")

    handler_id = "failed-job-alert-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.maintenance_failed_job_alert_stop(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = FailedJobAlertWorker.perform(%Oban.Job{args: %{}})
      end)

    assert log =~ "maintenance_failed_jobs_detected"

    assert_receive {:telemetry, [:event_sales, :maintenance, :failed_job_alert, :stop],
                    %{count: 1, duration: duration},
                    %{
                      worker: :failed_job_alert_worker,
                      affected_count: 1,
                      cancelled_count: 0,
                      reason: :threshold_exceeded
                    }},
                   500

    assert is_integer(duration)
    assert Repo.get!(Oban.Job, job.id).state == "discarded"
    assert Repo.get!(Oban.Job, job.id).attempt == job.attempt
  end

  test "keeps cancelled jobs separate from discarded alert count" do
    insert_job!("cancelled")

    handler_id = "cancelled-job-alert-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.maintenance_failed_job_alert_stop(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert :ok = FailedJobAlertWorker.perform(%Oban.Job{args: %{}})
      end)

    refute log =~ "maintenance_failed_jobs_detected"

    assert_receive {:telemetry, [:event_sales, :maintenance, :failed_job_alert, :stop],
                    %{count: 0},
                    %{
                      affected_count: 0,
                      cancelled_count: 1,
                      reason: :below_threshold
                    }},
                   500
  end

  defp insert_job!(state) do
    now = DateTime.utc_now()

    Repo.insert!(%Oban.Job{
      args: %{"kind" => "maintenance-test"},
      worker: "EventSales.TestWorker",
      queue: "default",
      state: state,
      attempt: 1,
      max_attempts: 1,
      attempted_at: DateTime.add(now, -3600, :second),
      completed_at: DateTime.add(now, -3500, :second),
      discarded_at: if(state == "discarded", do: DateTime.add(now, -3500, :second)),
      cancelled_at: if(state == "cancelled", do: DateTime.add(now, -3500, :second)),
      inserted_at: DateTime.add(now, -3700, :second),
      scheduled_at: DateTime.add(now, -3700, :second),
      priority: 0,
      errors: [],
      tags: [],
      meta: %{}
    })
  end
end
