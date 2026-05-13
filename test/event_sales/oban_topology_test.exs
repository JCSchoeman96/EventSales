defmodule EventSales.ObanTopologyTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Repo
  alias EventSales.TestSupport.ObanHelpers
  alias Oban.Job

  test "oban is supervised in test" do
    assert Enum.any?(Supervisor.which_children(EventSales.Supervisor), fn
             {Oban, pid, :supervisor, [Oban]} when is_pid(pid) -> true
             _child -> false
           end)
  end

  test "a test job can be inserted and executed deterministically" do
    job = ObanHelpers.insert_test_job(%{marker: "slice-0.2"})

    assert_enqueued(worker: ObanHelpers.TestWorker, args: %{marker: "slice-0.2"})
    assert %{success: 1, failure: 0, snoozed: 0} = Oban.drain_queue(queue: :default)

    assert %Job{state: "completed"} = Repo.get!(Job, job.id)
  end
end
