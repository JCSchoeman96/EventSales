defmodule EventSales.SmokeTest.ObanTopology do
  @moduledoc false

  alias EventSales.Maintenance.ObanTopologySmokeWorker
  alias EventSales.Release
  alias EventSales.Repo
  alias Oban.Job

  @valid_modes ~w(local production_like)

  def run do
    mode = System.get_env("SMOKE_TOPOLOGY_MODE", "local")
    timeout_ms = parse_positive_integer!("SMOKE_TIMEOUT_MS", 30_000)
    poll_interval_ms = parse_positive_integer!("SMOKE_POLL_INTERVAL_MS", 500)

    unless mode in @valid_modes do
      Mix.raise("SMOKE_TOPOLOGY_MODE must be one of: #{Enum.join(@valid_modes, ", ")}")
    end

    Mix.Task.run("app.start")

    oban_config = Application.fetch_env!(:event_sales, Oban)

    ensure_real_oban!(oban_config)
    ensure_repo_running!()
    ensure_oban_supervised!()

    run_id = "slice-5-7-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    success_job = insert_job!("success", run_id)
    retry_job = insert_job!("fail_once", run_id)

    success_job = wait_until_completed!(success_job.id, timeout_ms, poll_interval_ms)
    retry_job = wait_until_completed!(retry_job.id, timeout_ms, poll_interval_ms)

    unless retry_job.attempt > 1 do
      Mix.raise("fail_once job completed without retrying; attempt=#{inspect(retry_job.attempt)}")
    end

    if Enum.empty?(retry_job.errors || []) do
      Mix.raise("fail_once job completed without a persisted error entry")
    end

    Mix.shell().info("""
    Slice 5.7 Oban topology smoke test passed.
    |> smoke_topology_mode: #{mode}
    |> runtime_db_source: #{runtime_db_source()}
    |> migration_db_source: #{migration_db_source()}
    |> configured_notifier: #{notifier_name(oban_config)}
    |> queue_config: #{inspect(Keyword.fetch!(oban_config, :queues))}
    |> timeout_ms: #{timeout_ms}
    |> poll_interval_ms: #{poll_interval_ms}
    |> success_job_id: #{success_job.id}
    |> success_final_state: #{success_job.state}
    |> fail_once_job_id: #{retry_job.id}
    |> fail_once_final_state: #{retry_job.state}
    |> fail_once_attempt: #{retry_job.attempt}
    |> fail_once_error_count: #{length(retry_job.errors || [])}
    """)
  end

  defp insert_job!(mode, run_id) do
    %{mode: mode, run_id: run_id}
    |> ObanTopologySmokeWorker.new()
    |> Oban.insert!()
  end

  defp wait_until_completed!(job_id, timeout_ms, poll_interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_completed!(job_id, deadline, poll_interval_ms)
  end

  defp do_wait_until_completed!(job_id, deadline, poll_interval_ms) do
    job = Repo.get!(Job, job_id)

    cond do
      job.state == "completed" ->
        job

      System.monotonic_time(:millisecond) >= deadline ->
        Mix.raise("""
        Oban smoke job #{job_id} did not complete before timeout.
        final_state=#{inspect(job.state)}
        attempt=#{inspect(job.attempt)}
        errors=#{inspect(job.errors || [])}
        """)

      true ->
        Process.sleep(poll_interval_ms)
        do_wait_until_completed!(job_id, deadline, poll_interval_ms)
    end
  end

  defp ensure_real_oban!(oban_config) do
    case Keyword.get(oban_config, :testing, false) do
      false ->
        :ok

      testing_mode ->
        Mix.raise("""
        Oban topology smoke test requires real queue execution.
        Remove test-only Oban testing mode before running this script.
        configured_testing=#{inspect(testing_mode)}
        """)
    end
  end

  defp ensure_repo_running! do
    unless Process.whereis(Repo) do
      Mix.raise("EventSales.Repo is not running")
    end
  end

  defp ensure_oban_supervised! do
    oban_running? =
      Enum.any?(Supervisor.which_children(EventSales.Supervisor), fn
        {Oban, pid, :supervisor, [Oban]} when is_pid(pid) -> true
        _child -> false
      end)

    unless oban_running? do
      Mix.raise("Oban is not supervised by EventSales.Supervisor")
    end
  end

  defp runtime_db_source do
    repo_config = Repo.config()

    cond do
      present?(System.get_env("DATABASE_URL")) ->
        "DATABASE_URL"

      present?(repo_config[:url]) ->
        "EventSales.Repo configured url"

      present?(repo_config[:database]) ->
        "EventSales.Repo local config database=#{repo_config[:database]} host=#{repo_config[:hostname] || "unknown"}"

      true ->
        "unknown"
    end
  end

  defp migration_db_source do
    env = System.get_env()

    case Release.migration_database_url(env) do
      {:ok, _url} ->
        cond do
          present?(Map.get(env, "DIRECT_DATABASE_URL")) -> "DIRECT_DATABASE_URL"
          present?(Map.get(env, "DATABASE_URL")) -> "DATABASE_URL fallback"
          true -> "unknown"
        end

      {:error, _message} ->
        "not configured in environment"
    end
  end

  defp notifier_name(oban_config) do
    case Keyword.get(oban_config, :notifier) do
      nil -> "Oban default / Postgres notifier assumed"
      notifier when is_atom(notifier) -> inspect(notifier)
      notifier -> inspect(notifier)
    end
  end

  defp parse_positive_integer!(env_name, default) do
    env_name
    |> System.get_env(to_string(default))
    |> Integer.parse()
    |> case do
      {value, ""} when value > 0 -> value
      _invalid -> Mix.raise("#{env_name} must be a positive integer")
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

EventSales.SmokeTest.ObanTopology.run()
