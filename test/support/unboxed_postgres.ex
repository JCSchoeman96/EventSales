defmodule EventSales.TestSupport.UnboxedPostgres do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Repo

  @lock {:event_sales, :unboxed_postgres}

  def start_link! do
    :ok
  end

  def with_connection(fun) when is_function(fun, 0) do
    depth = Process.get(:unboxed_postgres_depth, 0)

    if depth > 0 do
      fun.()
    else
      :global.trans(@lock, fn ->
        Process.put(:unboxed_postgres_depth, 1)

        try do
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            fun.()
          after
            Sandbox.checkin(Repo)
          end
        after
          Process.delete(:unboxed_postgres_depth)
        end
      end)
    end
  end
end
