ExUnit.start(exclude: [:pending, :m5_04_certification_load])
Ecto.Adapters.SQL.Sandbox.mode(EventSales.Repo, :manual)
EventSales.TestSupport.UnboxedPostgres.start_link!()
