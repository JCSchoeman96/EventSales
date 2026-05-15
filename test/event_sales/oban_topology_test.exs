defmodule EventSales.ObanTopologyTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Maintenance.ObanTopologySmokeWorker
  alias EventSales.Repo
  alias Oban.Job

  test "oban notifier and queues are explicit" do
    oban_config = Application.fetch_env!(:event_sales, Oban)

    assert Keyword.fetch!(oban_config, :notifier) == Oban.Notifiers.Postgres
    assert Keyword.fetch!(oban_config, :plugins) == []
    assert Keyword.fetch!(oban_config, :queues)[:default] == 10
    assert Keyword.fetch!(oban_config, :queues)[:webhooks] == 10
  end

  test "oban is supervised in test" do
    assert Enum.any?(Supervisor.which_children(EventSales.Supervisor), fn
             {Oban, pid, :supervisor, [Oban]} when is_pid(pid) -> true
             _child -> false
           end)
  end

  test "smoke worker success job can be inserted and executed deterministically" do
    job =
      %{mode: "success", marker: "slice-5-7-success"}
      |> ObanTopologySmokeWorker.new()
      |> Oban.insert!()

    assert_enqueued(
      worker: ObanTopologySmokeWorker,
      args: %{mode: "success", marker: "slice-5-7-success"}
    )

    assert %{success: 1, failure: 0, snoozed: 0} = Oban.drain_queue(queue: :default)

    assert %Job{state: "completed"} = Repo.get!(Job, job.id)
  end

  test "smoke worker fail_once job records an error and completes on retry" do
    job =
      %{mode: "fail_once", marker: "slice-5-7-retry"}
      |> ObanTopologySmokeWorker.new()
      |> Oban.insert!()

    assert %{success: 1, failure: 1, snoozed: 0} =
             Oban.drain_queue(queue: :default, with_recursion: true, with_scheduled: true)

    assert %Job{state: "completed", attempt: attempt, errors: errors} = Repo.get!(Job, job.id)
    assert attempt > 1
    assert [_error | _] = errors
  end
end
