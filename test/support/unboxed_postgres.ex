defmodule EventSales.TestSupport.UnboxedPostgres do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Repo

  @setup_lock {:event_sales, :unboxed_postgres_setup}

  def start_link! do
    :ok
  end

  @doc """
  Runs a callback on an independent sandbox-disabled connection.

  Multiple processes may hold unboxed connections concurrently.
  """
  def with_connection(fun) when is_function(fun, 0) do
    run_unboxed(fun)
  end

  @doc """
  Serializes fixture setup/teardown that must not race other tests.
  """
  def with_exclusive_setup(fun) when is_function(fun, 0) do
    :global.trans(@setup_lock, fn -> run_unboxed(fun) end)
  end

  defp run_unboxed(fun) do
    depth = Process.get(:unboxed_postgres_depth, 0)

    if depth > 0 do
      fun.()
    else
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Process.put(:ecto_sandbox_unboxed, true)
      Process.put(:unboxed_postgres_depth, 1)

      try do
        fun.()
      after
        Process.delete(:ecto_sandbox_unboxed)
        Process.delete(:unboxed_postgres_depth)
        Sandbox.checkin(Repo)
      end
    end
  end
end
