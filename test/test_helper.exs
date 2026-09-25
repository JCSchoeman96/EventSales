ExUnit.start(exclude: [:pending])
Ecto.Adapters.SQL.Sandbox.mode(EventSales.Repo, :manual)
EventSales.TestSupport.UnboxedPostgres.start_link!()
