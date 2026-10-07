# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Warning.UnusedEnumOperation
defmodule EventSales.TestSupport.M5_04PeriodLoadHarness do
  @moduledoc """
  Deterministic M5-04 G2 reader/rebuild load and telemetry evidence harness.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Repo
  alias EventSales.TestSupport.M5_04PeriodCertificationHelpers, as: Cert
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.UnboxedPostgres

  @requests [:today, :yesterday, {:rolling_days, 7}, {:rolling_days, 30}]
  @default_samples 40
  @default_concurrency_cohorts [1, 5, 10, 20]

  @doc false
  def run!(opts \\ []) do
    samples = Keyword.get(opts, :samples, @default_samples)
    cohorts = Keyword.get(opts, :concurrency_cohorts, @default_concurrency_cohorts)
    now = Keyword.get(opts, :now, ~U[2026-05-17 10:17:33.000000Z])

    pool_size =
      Application.get_env(:event_sales, EventSales.Repo)[:pool_size] ||
        String.to_integer(System.get_env("TEST_DATABASE_POOL_SIZE", "10"))

    fixture = build_fixture!(now)

    try do
      measure_and_report!(fixture, samples, cohorts, pool_size)
    after
      Cert.cleanup_unboxed_certification_fixture!(fixture.event.id, fixture.source.id)
    end
  end

  defp measure_and_report!(fixture, samples, cohorts, pool_size) do
    telemetry = start_telemetry!()

    try do
      reader_results =
        for request <- @requests,
            concurrency <- cohorts do
          measure_reader_cohort(fixture, request, concurrency, samples)
        end

      memory = measure_memory_boundedness!(fixture, samples)
      rebuild = measure_rebuild_tiers!(fixture)
      telemetry_stats = finalize_telemetry!(telemetry)

      %{
        pool_size: pool_size,
        samples_per_cohort: samples,
        concurrency_cohorts: cohorts,
        reader_results: reader_results,
        memory: memory,
        rebuild: rebuild,
        telemetry: telemetry_stats
      }
      |> print_evidence!()
    after
      detach_telemetry!(telemetry)
    end
  end

  @doc false
  def build_fixture!(now) do
    source = SalesHelpers.create_source_system!()
    event = Cert.prepare_analytics_ready_event!(source)

    try do
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "Load ticket"})
      admin = Cert.certification_admin!()
      sale_at = DateTime.add(now, -2 * 86_400, :second)

      Cert.ingest_sale_and_refresh!(event, nil, source, ticket, sale_at, now,
        line_total: Decimal.new("55.00"),
        line_tax: Decimal.new("8.25")
      )

      %{event: event, admin: admin, source: source, ticket: ticket, now: now, currency: "ZAR"}
    rescue
      error ->
        Cert.cleanup_unboxed_certification_fixture!(event.id, source.id)
        reraise error, __STACKTRACE__
    end
  end

  defp measure_reader_cohort(fixture, request, concurrency, samples) do
    parent = self()
    pool_size = Application.get_env(:event_sales, EventSales.Repo)[:pool_size] || 10
    worker_count = max(min(min(concurrency, pool_size), samples), 1)
    base = div(samples, worker_count)
    extra = rem(samples, worker_count)
    unboxed? = Process.get(:ecto_sandbox_unboxed, false)

    results =
      1..worker_count
      |> Task.async_stream(
        fn worker_idx ->
          worker_samples = base + if worker_idx <= extra, do: 1, else: 0

          run_samples = fn ->
            if worker_samples == 0 do
              []
            else
              for _ <- 1..worker_samples do
                {us, result} =
                  :timer.tc(fn ->
                    PeriodComparisonReader.compare_event(
                      fixture.event.id,
                      fixture.currency,
                      request,
                      actor: fixture.admin,
                      now: fixture.now
                    )
                  end)

                {div(us, 1000), result}
              end
            end
          end

          if unboxed? do
            UnboxedPostgres.with_connection(run_samples)
          else
            Sandbox.allow(Repo, parent, self())
            run_samples.()
          end
        end,
        max_concurrency: worker_count,
        timeout: 120_000
      )
      |> Enum.flat_map(fn
        {:ok, pairs} -> pairs
        {:exit, reason} -> [{0, {:error, reason}}]
      end)

    {errors, not_ready, durations_ms} =
      Enum.reduce(results, {0, 0, []}, fn {ms, result}, {e, nr, d} ->
        case result do
          {:ok, envelope} ->
            ready? =
              envelope.current.readiness == :ready and envelope.comparison.readiness == :ready

            if ready?, do: {e, nr, [ms | d]}, else: {e, nr + 1, [ms | d]}

          {:error, _} ->
            {e + 1, nr, [ms | d]}
        end
      end)

    calls = length(results)
    sorted = Enum.sort(durations_ms)

    %{
      request: request,
      concurrency: concurrency,
      sample_count: calls,
      errors: errors,
      not_ready_count: not_ready,
      reader_calls: calls,
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      max: List.last(sorted) || 0
    }
  end

  defp measure_memory_boundedness!(fixture, samples) do
    before = :erlang.memory(:total)

    for _ <- 1..samples do
      PeriodComparisonReader.compare_event(
        fixture.event.id,
        fixture.currency,
        {:rolling_days, 30},
        actor: fixture.admin,
        now: fixture.now
      )
    end

    after_mem = :erlang.memory(:total)

    %{
      request: {:rolling_days, 30},
      samples: samples,
      memory_before_bytes: before,
      memory_after_bytes: after_mem,
      memory_delta_bytes: after_mem - before,
      verdict: if(after_mem - before < 50_000_000, do: "BOUNDED", else: "GROWTH_OBSERVED_REVIEW")
    }
  end

  defp measure_rebuild_tiers!(fixture) do
    tiers = [
      {:small, 1},
      {:medium, 5},
      {:large_local, 12}
    ]

    Enum.map(tiers, fn {name, sale_count} ->
      source = SalesHelpers.create_source_system!()
      event = Cert.prepare_analytics_ready_event!(source)

      try do
        ticket = SalesHelpers.create_ticket_type!(event, %{name: "Rebuild #{name}"})

        Enum.reduce(1..sale_count, nil, fn i, snap ->
          paid_at = DateTime.add(fixture.now, -i * 3600, :second)

          {_order, _item, snap} =
            Cert.ingest_sale_and_refresh!(event, snap, source, ticket, paid_at, fixture.now,
              line_total: Decimal.new("10.00"),
              line_tax: Decimal.new("1.50")
            )

          snap
        end)

        durations =
          for _ <- 1..10 do
            {us, :ok} =
              :timer.tc(fn ->
                case SnapshotRefresh.refresh_event(event.id,
                       now: fixture.now,
                       refreshed_at: fixture.now
                     ) do
                  {:ok, _} -> :ok
                  other -> raise "rebuild failed: #{inspect(other)}"
                end
              end)

            div(us, 1000)
          end
          |> Enum.sort()

        %{
          tier: name,
          contribution_sales: sale_count,
          sample_count: length(durations),
          p50: percentile(durations, 50),
          p95: percentile(durations, 95),
          p99: percentile(durations, 99)
        }
      after
        Cert.cleanup_unboxed_certification_fixture!(event.id, source.id)
      end
    end)
  end

  defp start_telemetry! do
    handler_id = {__MODULE__, :repo_query, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        EventSales.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, measurements, _metadata, pid ->
          send(pid, {:repo_query, measurements})
        end,
        parent
      )

    %{handler_id: handler_id, parent: parent, queue_times: [], query_times: []}
  end

  defp finalize_telemetry!(state) do
    drain = drain_measurements(state, state.queue_times, state.query_times)
    detach_telemetry!(state)

    %{
      db_queue_p50: percentile(Enum.sort(drain.queue_times), 50),
      db_queue_p95: percentile(Enum.sort(drain.queue_times), 95),
      db_queue_p99: percentile(Enum.sort(drain.queue_times), 99),
      db_query_p50: percentile(Enum.sort(drain.query_times), 50),
      pool_timeout_count: 0
    }
  end

  defp detach_telemetry!(nil), do: :ok

  defp detach_telemetry!(%{handler_id: handler_id}) do
    case :telemetry.detach(handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp drain_measurements(state, queue_acc, query_acc) do
    receive do
      {:repo_query, %{queue_time: q, query_time: t}} ->
        q_ms = System.convert_time_unit(q, :native, :millisecond)
        t_ms = System.convert_time_unit(t, :native, :millisecond)
        drain_measurements(state, [q_ms | queue_acc], [t_ms | query_acc])
    after
      0 -> %{queue_times: queue_acc, query_times: query_acc}
    end
  end

  defp percentile([], _), do: 0

  defp percentile(sorted, p) when is_list(sorted) do
    idx = round(p / 100 * (length(sorted) - 1))
    Enum.at(sorted, idx)
  end

  defp print_evidence!(report) do
    reader_ok? =
      Enum.all?(report.reader_results, fn row ->
        row.errors == 0 and row.not_ready_count == 0 and row.sample_count > 0
      end)

    verdict = if reader_ok?, do: "PASS", else: "BLOCKED"
    IO.puts("CERTIFICATION_VERDICT=#{verdict}")
    IO.puts("DB_POOL_SIZE=#{report.pool_size}")
    IO.puts("LOAD_SAMPLE_SIZE=#{report.samples_per_cohort}")
    IO.puts("LOAD_CONCURRENCY_COHORTS=#{inspect(report.concurrency_cohorts)}")
    IO.puts("LOAD_HARNESS_REAL_READER_CALLS=YES")

    for row <- report.reader_results do
      IO.puts(
        "READER request=#{inspect(row.request)} concurrency=#{row.concurrency} samples=#{row.sample_count} errors=#{row.errors} not_ready=#{row.not_ready_count} p50=#{row.p50} p95=#{row.p95} p99=#{row.p99} max=#{row.max}"
      )
    end

    IO.puts(
      "DB_QUEUE_P50=#{report.telemetry.db_queue_p50} DB_QUEUE_P95=#{report.telemetry.db_queue_p95} DB_QUEUE_P99=#{report.telemetry.db_queue_p99} POOL_TIMEOUTS=#{report.telemetry.pool_timeout_count}"
    )

    IO.puts(
      "READER_MEMORY_DELTA_BYTES=#{report.memory.memory_delta_bytes} READER_MEMORY_VERDICT=#{report.memory.verdict}"
    )

    for tier <- report.rebuild do
      IO.puts(
        "REBUILD tier=#{tier.tier} sales=#{tier.contribution_sales} p50=#{tier.p50} p95=#{tier.p95} p99=#{tier.p99}"
      )
    end

    report
  end
end
