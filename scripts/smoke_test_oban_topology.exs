Mix.Task.run("app.start")

alias EventSales.Release
alias EventSales.Repo
alias EventSales.TestSupport.ObanHelpers
alias Oban.Job
alias Ecto.Adapters.SQL.Sandbox

unless function_exported?(Sandbox, :checkout, 1) do
  raise "expected SQL sandbox support in test mode"
end

:ok = Sandbox.checkout(Repo)

direct_database_url = System.get_env("DIRECT_DATABASE_URL")
repo_config = Repo.config()

migration_source =
  case Release.migration_database_url(System.get_env()) do
    {:ok, _url} ->
      if is_binary(direct_database_url) and String.trim(direct_database_url) != "" do
        "DIRECT_DATABASE_URL"
      else
        "DATABASE_URL fallback"
      end

    {:error, message} ->
      if is_binary(repo_config[:url]) and String.trim(repo_config[:url]) != "" do
        "test repo url fallback"
      else
        has_local_repo_config? =
          is_binary(repo_config[:database]) and String.trim(repo_config[:database]) != "" and
            is_binary(repo_config[:hostname]) and String.trim(repo_config[:hostname]) != ""

        if has_local_repo_config? do
          "test repo config fallback"
        else
          raise message
        end
      end
  end

unless Process.whereis(Repo) do
  raise "EventSales.Repo is not running"
end

oban_running? =
  Enum.any?(Supervisor.which_children(EventSales.Supervisor), fn
    {Oban, pid, :supervisor, [Oban]} when is_pid(pid) -> true
    _child -> false
  end)

unless oban_running? do
  raise "Oban is not supervised by EventSales.Supervisor"
end

job = ObanHelpers.insert_test_job(%{marker: "slice-0.2-smoke"})
drain_result = Oban.drain_queue(queue: :default)
reloaded_job = Repo.get!(Job, job.id)

unless match?(%{success: 1, failure: 0, snoozed: 0}, drain_result) do
  raise "unexpected drain result: #{inspect(drain_result)}"
end

unless reloaded_job.state == "completed" do
  raise "expected smoke-test job to complete, got #{inspect(reloaded_job.state)}"
end

Mix.shell().info("""
Slice 0.2 Oban topology smoke test passed.
|> repo: running
|> oban: supervised
|> migration_url_source: #{migration_source}
|> inserted_job_id: #{job.id}
|> final_state: #{reloaded_job.state}
""")
