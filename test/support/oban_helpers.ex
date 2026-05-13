defmodule EventSales.TestSupport.ObanHelpers do
  @moduledoc """
  Minimal test-only helpers for proving Oban baseline behavior.
  """

  alias Oban.Job

  defmodule TestWorker do
    @moduledoc false

    use Oban.Worker, queue: :default, max_attempts: 1

    @impl Oban.Worker
    def perform(%Job{}), do: :ok
  end

  @spec insert_test_job(map()) :: Job.t()
  def insert_test_job(args \\ %{}) when is_map(args) do
    args
    |> TestWorker.new()
    |> Oban.insert!()
  end
end
