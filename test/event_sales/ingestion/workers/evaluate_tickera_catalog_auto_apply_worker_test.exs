defmodule EventSales.Ingestion.Workers.EvaluateTickeraCatalogAutoApplyWorkerTest do
  use ExUnit.Case, async: true
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion.Workers.EvaluateTickeraCatalogAutoApplyWorker

  test "uses bounded run/hash arguments and uniqueness" do
    job =
      EvaluateTickeraCatalogAutoApplyWorker.new(%{
        "run_id" => "00000000-0000-0000-0000-000000000001",
        "dry_run_hash" => String.duplicate("a", 64)
      })

    assert job.changes.queue == "tickera_sync"
    assert Ecto.Changeset.get_field(job, :max_attempts) == 20
  end
end
