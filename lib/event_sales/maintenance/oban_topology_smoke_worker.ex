defmodule EventSales.Maintenance.ObanTopologySmokeWorker do
  @moduledoc """
  Real Oban worker used by Slice 5.7 topology smoke tests.

  This worker intentionally lives in `lib/` so production-like smoke checks can
  prove normal Oban execution without depending on ExUnit, SQL sandbox, or
  test-only worker modules.
  """

  use Oban.Worker, queue: :default, max_attempts: 2

  alias Oban.Job

  @impl Oban.Worker
  @spec perform(Job.t()) ::
          :ok | {:error, :intentional_smoke_failure} | {:discard, :unsupported_smoke_mode}
  def perform(%Job{args: %{"mode" => "success"}}), do: :ok

  def perform(%Job{args: %{"mode" => "fail_once"}, attempt: 1}) do
    {:error, :intentional_smoke_failure}
  end

  def perform(%Job{args: %{"mode" => "fail_once"}}), do: :ok

  def perform(%Job{}), do: {:discard, :unsupported_smoke_mode}

  @impl Oban.Worker
  @spec backoff(Job.t()) :: pos_integer()
  def backoff(%Job{args: %{"mode" => "fail_once"}}), do: 1
  def backoff(%Job{} = job), do: Oban.Worker.backoff(job)
end
