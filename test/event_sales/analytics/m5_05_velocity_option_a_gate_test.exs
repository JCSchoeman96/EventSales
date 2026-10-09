# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule EventSales.Analytics.M5_05VelocityOptionAGateTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.{
    EventSnapshotRefreshFence,
    PeriodReadPlan,
    ProjectionPeriodReader,
    TimeRules
  }

  alias EventSales.Repo
  alias EventSales.TestSupport.M5_04PeriodCertificationHelpers, as: Certification
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.UnboxedPostgres

  @base_sha "7dec4997ea80cb8add5cc1ddc7e82f90b21afbf9"
  @base_tree "d9185454e9cb60479bdfe3244e9c82c11bbb90a1"
  @canonical_path "test/event_sales/analytics/m5_05_velocity_option_a_gate_test.exs"
  @evidence_path "tmp/m5_05_velocity_option_a_gate_evidence.txt"
  @required_index "analytics_contribution_facts_event_currency_effective_at_idx"
  @coverage "m5_05d1_option_a_gate_v1"
  @pool_size 10
  @cohorts [1, 20, 50]
  @samples 100
  @warmups 10
  @normal_facts_per_hour 200
  @high_facts_per_hour 20_000
  @background_total 20_000
  @normal_limit_us 100_000
  @high_limit_us 150_000
  @densities [:normal, :high_density]
  @cases [
    %{id: "15m_unaligned", now: ~U[2026-05-17 10:17:33Z], request: {:rolling_minutes, 15}},
    %{id: "30m_unaligned", now: ~U[2026-05-17 10:17:33Z], request: {:rolling_minutes, 30}},
    %{id: "60m_unaligned", now: ~U[2026-05-17 10:17:33Z], request: {:rolling_minutes, 60}},
    %{id: "60m_aligned", now: ~U[2026-05-17 11:00:00Z], request: {:rolling_minutes, 60}}
  ]
  @background_counts %{other_event: 6_667, other_currency: 6_667, outside_time: 6_666}

  test "the explicit invocation detector accepts only the canonical file argument" do
    assert explicit_invocation?(["test", @canonical_path])
    refute explicit_invocation?(["test"])
    refute explicit_invocation?(["test", "test/event_sales/analytics"])
    refute explicit_invocation?(["test", @canonical_path <> ":12"])
  end

  test "the report matrix has two densities, four cases, and three cohorts" do
    assert length(@densities) * length(@cases) * length(@cohorts) == 24
    assert length(matrix_rows()) == 24
  end

  test "percentiles use the frozen M5-04 nearest-index convention" do
    assert percentile(Enum.to_list(1..100), 50) == 51
    assert percentile(Enum.to_list(1..100), 95) == 95
    assert percentile(Enum.to_list(1..100), 99) == 99
  end

  @tag :m5_05_d1_certification_load
  test "runs the explicit D1 Option-A measurement gate" do
    if explicit_invocation?(System.argv()) do
      IO.puts("D1_EXPLICIT_INVOCATION=YES")
      report = run_gate()
      print_summary(report)
      assert report.measurement_valid, "MEASUREMENT_VALID=NO, see #{@evidence_path}"
      assert length(report.measurement_rows) == 24
      assert length(report.explain_rows) == 6
    else
      IO.puts("D1_EXPLICIT_INVOCATION=NO")
      IO.puts("D1_HEAVY_BODY=SKIPPED")
    end
  end

  defp explicit_invocation?(argv) do
    Enum.any?(argv, &(&1 == @canonical_path))
  end

  defp matrix_rows do
    for density <- @densities, case_spec <- @cases, cohort <- @cohorts do
      %{density: density, case: case_spec.id, requested_concurrency: cohort}
    end
  end

  defp run_gate do
    prior_attempts = prior_invalid_attempts!()
    telemetry_table = :ets.new(:m5_05_d1_query_events, [:bag, :public])
    handler_id = {__MODULE__, make_ref()}
    attach_telemetry!(handler_id, telemetry_table)

    report = Map.put(initial_report(), :prior_invalid_attempts, prior_attempts)

    result =
      try do
        verify_test_database!()

        Enum.reduce(@densities, report, fn density, acc ->
          run_density!(density, telemetry_table, acc)
        end)
        |> finalize_report()
      rescue
        error ->
          report
          |> Map.put(:measurement_valid, false)
          |> Map.put(:invalid_reason, Exception.message(error))
          |> Map.put(:preliminary_option_a, "NOT_EVALUATED")
      catch
        kind, reason ->
          report
          |> Map.put(:measurement_valid, false)
          |> Map.put(:invalid_reason, "#{kind}: #{inspect(reason)}")
          |> Map.put(:preliminary_option_a, "NOT_EVALUATED")
      after
        :telemetry.detach(handler_id)
        :ets.delete(telemetry_table)
      end

    result = Map.merge(result, head_identity())
    write_evidence!(result)
    result
  end

  defp initial_report do
    %{
      base_sha: @base_sha,
      base_tree: @base_tree,
      configuration: %{
        normal_edge_facts_per_touched_utc_hour: @normal_facts_per_hour,
        high_density_edge_facts_per_touched_utc_hour: @high_facts_per_hour,
        selectivity_background_facts: @background_total,
        concurrency_cohorts: @cohorts,
        samples_per_case_per_cohort: @samples,
        warmup_calls_per_case: @warmups,
        test_database_pool_size: @pool_size,
        normal_c50_p99_max_us: @normal_limit_us,
        high_density_c50_p99_max_us: @high_limit_us
      },
      fixture_counts: [],
      measurement_rows: [],
      explain_rows: [],
      query_shape_rows: [],
      measurement_valid: true
    }
  end

  defp run_density!(density, telemetry_table, report) do
    fixture =
      UnboxedPostgres.with_exclusive_setup(fn ->
        build_fixture!(density)
      end)

    try do
      report = Map.update!(report, :fixture_counts, &[fixture.counts | &1])

      Enum.reduce(@cases, report, fn case_spec, acc ->
        plan = build_plan!(case_spec)
        probe = probe_read!(fixture, plan, telemetry_table)
        shape = query_shape(probe.queries, case_spec)

        acc = Map.update!(acc, :query_shape_rows, &[shape | &1])
        acc = maybe_explain!(acc, fixture, case_spec, probe)

        Enum.each(1..@warmups, fn _ ->
          warmup = read_once(fixture, plan, nil)
          assert_ready_result!(warmup.result, plan)
        end)

        Enum.reduce(@cohorts, acc, fn cohort, cohort_acc ->
          row = measure_cohort!(fixture, plan, density, case_spec, cohort, telemetry_table)
          Map.update!(cohort_acc, :measurement_rows, &[row | &1])
        end)
      end)
    after
      UnboxedPostgres.with_exclusive_setup(fn ->
        :ok = Certification.cleanup_unboxed_certification_source!(fixture.source.id)
      end)
    end
  end

  defp build_fixture!(density) do
    source = Certification.create_unboxed_certification_source!()

    try do
      event = SalesHelpers.create_event!(source, %{name: "M5-05D1 measured #{density}"})
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "M5-05D1 measured ticket"})
      noise_event = SalesHelpers.create_event!(source, %{name: "M5-05D1 noise #{density}"})

      noise_ticket =
        SalesHelpers.create_ticket_type!(noise_event, %{name: "M5-05D1 noise ticket"})

      plans = Map.new(@cases, fn item -> {item.id, build_plan!(item)} end)
      touched_hours = touched_hours!(plans)

      facts_per_hour =
        if density == :normal, do: @normal_facts_per_hour, else: @high_facts_per_hour

      event_id = uuid_binary!(event.id)
      source_id = uuid_binary!(source.id)
      ticket_id = uuid_binary!(ticket.id)
      noise_event_id = uuid_binary!(noise_event.id)
      noise_ticket_id = uuid_binary!(noise_ticket.id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Enum.each(touched_hours, fn hour ->
        insert_fact_batch!(facts_per_hour, event_id, source_id, ticket_id, "ZAR", hour, now)
      end)

      outside_start = outside_background_hour!(plans)

      insert_fact_batch!(
        @background_counts.other_event,
        noise_event_id,
        source_id,
        noise_ticket_id,
        "ZAR",
        ~U[2026-05-17 09:00:00Z],
        now
      )

      insert_fact_batch!(
        @background_counts.other_currency,
        event_id,
        source_id,
        ticket_id,
        "USD",
        ~U[2026-05-17 09:00:00Z],
        now
      )

      insert_fact_batch!(
        @background_counts.outside_time,
        event_id,
        source_id,
        ticket_id,
        "ZAR",
        outside_start,
        now
      )

      seed_snapshots!(event.id, plans, touched_hours, facts_per_hour, now)
      Repo.query!("ANALYZE analytics_contribution_facts", [])

      counts =
        fixture_cardinalities!(
          event_id,
          noise_event_id,
          touched_hours,
          facts_per_hour,
          outside_start
        )

      security = database_identity!()

      %{
        density: density,
        source: source,
        event: event,
        ticket: ticket,
        noise_event: noise_event,
        noise_ticket: noise_ticket,
        plans: plans,
        touched_hours: touched_hours,
        facts_per_hour: facts_per_hour,
        counts:
          Map.merge(counts, %{touched_utc_hours: Enum.map(touched_hours, &DateTime.to_iso8601/1)}),
        security: security
      }
    rescue
      error ->
        :ok = Certification.cleanup_unboxed_certification_source!(source.id)
        reraise error, __STACKTRACE__
    end
  end

  defp build_plan!(%{now: now, request: request}) do
    {:ok, windows} = TimeRules.velocity_windows(now, request)
    {:ok, plan} = PeriodReadPlan.build(windows)
    plan
  end

  defp touched_hours!(plans) do
    hours =
      ["15m_unaligned", "30m_unaligned", "60m_unaligned"]
      |> Enum.flat_map(fn id ->
        plan = Map.fetch!(plans, id)

        Enum.flat_map(plan.operands, fn operand ->
          Enum.map(operand.edge_fragments, & &1.envelope_hour_start_utc)
        end)
      end)
      |> Enum.uniq()
      |> Enum.sort(DateTime)

    if hours == [], do: raise("no touched edge hours")

    Enum.each(["15m_unaligned", "30m_unaligned", "60m_unaligned"], fn id ->
      if Map.fetch!(plans, id).edge_fragment_count == 0, do: raise("#{id} has no edge fragments")
    end)

    if Map.fetch!(plans, "60m_aligned").edge_fragment_count != 0,
      do: raise("aligned 60m plan has edge fragments")

    hours
  end

  defp outside_background_hour!(plans) do
    %DateTime{} =
      earliest_start =
      plans
      |> Map.values()
      |> Enum.flat_map(& &1.operands)
      |> Enum.map(& &1.period.start_utc)
      |> Enum.min(DateTime)

    earliest_hour = %DateTime{
      earliest_start
      | minute: 0,
        second: 0,
        microsecond: {0, 6}
    }

    DateTime.add(earliest_hour, -1, :hour)
  end

  defp seed_snapshots!(event_id, plans, touched_hours, facts_per_hour, now) do
    specs =
      plans
      |> Map.values()
      |> Enum.flat_map(fn plan ->
        Enum.flat_map(plan.operands, fn operand ->
          fixed = operand.fixed_buckets

          envelopes =
            Enum.map(operand.edge_fragments, fn fragment ->
              hour = fragment.envelope_hour_start_utc

              %{
                bucket_kind: :utc_hour,
                bucket_timezone: "UTC",
                bucket_start_utc: hour,
                bucket_end_utc: DateTime.add(hour, 1, :hour)
              }
            end)

          fixed ++ envelopes
        end)
      end)
      |> Enum.uniq_by(&{&1.bucket_kind, &1.bucket_start_utc, &1.bucket_end_utc})

    Enum.each(specs, fn spec ->
      count =
        if spec.bucket_kind == :utc_hour and spec.bucket_start_utc in touched_hours,
          do: facts_per_hour,
          else: 0

      PeriodComparisonHelpers.create_event_bucket!(event_id, "ZAR", spec, %{
        gross_ticket_quantity: count,
        gross_ticket_value: Decimal.new(count),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new(0),
        coverage_identity: @coverage,
        semantic_version: 1,
        projection_state: :current,
        refreshed_at: now
      })
    end)
  end

  defp insert_fact_batch!(count, event_id, source_id, ticket_id, currency, hour, now) do
    Repo.query!(
      """
      INSERT INTO analytics_contribution_facts (
        id, contribution_kind, source_contribution_id, event_id, currency, effective_at,
        ticket_type_id, source_system_id, woo_product_id, woo_variation_id,
        gross_ticket_quantity, gross_ticket_value, refund_ticket_quantity, refund_ticket_value,
        generation_id, semantic_version, coverage_identity, refreshed_at, inserted_at, updated_at
      )
      SELECT gen_random_uuid(), 'sale', gen_random_uuid(), $1::uuid, $2,
        $3::timestamptz + ((g.n - 1)::double precision * 3600 / $4) * interval '1 second',
        $5::uuid, $6::uuid, 81001, 81002, 1, 1.00, 0, 0,
        gen_random_uuid(), 1, $7, $8::timestamptz, $8::timestamptz, $8::timestamptz
      FROM generate_series(1, $4::integer) AS g(n)
      """,
      [
        event_id,
        currency,
        hour,
        count,
        ticket_id,
        source_id,
        @coverage,
        now
      ]
    )
  end

  defp fixture_cardinalities!(
         event_id,
         noise_event_id,
         touched_hours,
         facts_per_hour,
         outside_start
       ) do
    measured =
      count_facts!(
        "event_id = $1::uuid AND currency = 'ZAR' AND effective_at >= $2 AND effective_at < $3",
        [event_id, hd(touched_hours), DateTime.add(List.last(touched_hours), 1, :hour)]
      )

    other_event = count_facts!("event_id = $1::uuid AND currency = 'ZAR'", [noise_event_id])
    other_currency = count_facts!("event_id = $1::uuid AND currency = 'USD'", [event_id])

    outside_time =
      count_facts!(
        "event_id = $1::uuid AND currency = 'ZAR' AND effective_at >= $2 AND effective_at < $3",
        [event_id, outside_start, DateTime.add(outside_start, 1, :hour)]
      )

    expected_measured = length(touched_hours) * facts_per_hour

    actual = %{
      measured: measured,
      other_event: other_event,
      other_currency: other_currency,
      outside_time: outside_time
    }

    expected = %{
      measured: expected_measured,
      other_event: @background_counts.other_event,
      other_currency: @background_counts.other_currency,
      outside_time: @background_counts.outside_time
    }

    if actual != expected,
      do:
        raise(
          "INVALID_FIXTURE cardinality mismatch: #{inspect(%{actual: actual, expected: expected})}"
        )

    if Enum.sum(Map.values(Map.take(actual, [:other_event, :other_currency, :outside_time]))) !=
         @background_total,
       do: raise("INVALID_FIXTURE background total mismatch")

    Map.merge(actual, %{
      configured_measured: expected_measured,
      configured_background_total: @background_total,
      background_total: @background_total,
      background_outside_hour: DateTime.to_iso8601(outside_start)
    })
  end

  defp count_facts!(predicate, params) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM analytics_contribution_facts WHERE #{predicate}", params)

    count
  end

  defp database_identity! do
    %{rows: [[role, port, version, superuser]]} =
      Repo.query!(
        """
        SELECT current_user, inet_server_port(), current_setting('server_version_num')::integer,
               (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
        """,
        []
      )

    major = div(version, 10_000)
    pool_size = Application.get_env(:event_sales, Repo)[:pool_size]

    unless role == "eventsales_test" and port == 55_433 and major == 18 and superuser == false and
             pool_size == @pool_size do
      raise(
        "INVALID_ENVIRONMENT TEST identity mismatch: #{inspect(%{role: role, port: port, postgres_major: major, superuser: superuser, pool_size: pool_size})}"
      )
    end

    %{role: role, port: port, postgres_major: major, superuser: superuser, pool_size: pool_size}
  end

  defp verify_test_database! do
    if Application.get_env(:event_sales, Repo)[:pool_size] != @pool_size,
      do: raise("INVALID_ENVIRONMENT expected DB pool size #{@pool_size}")
  end

  defp probe_read!(fixture, plan, telemetry_table) do
    result = read_once(fixture, plan, make_ref())
    assert_ready_result!(result.result, plan)
    queries = queries_for_call!(telemetry_table, result.call_ref)
    %{queries: queries, result: result.result}
  end

  defp query_shape(queries, case_spec) do
    interactive = Enum.filter(queries, &interactive_query?/1)

    snapshot =
      Enum.count(
        interactive,
        &String.contains?(String.downcase(&1.sql), "analytics_event_period_aggregate_snapshots")
      )

    edge = Enum.count(interactive, &String.contains?(String.downcase(&1.sql), "from unnest"))

    unexpected =
      Enum.count(interactive, fn query ->
        sql = String.downcase(query.sql)

        not String.contains?(sql, "analytics_event_period_aggregate_snapshots") and
          not String.contains?(sql, "from unnest")
      end)

    raw = Enum.count(interactive, &raw_source_read?(&1.sql))
    expected_edge = if case_spec.id == "60m_aligned", do: 0, else: 1
    pass = snapshot == 1 and edge == expected_edge and unexpected == 0
    edge_query = Enum.find(interactive, &String.contains?(String.downcase(&1.sql), "from unnest"))

    %{
      case: case_spec.id,
      snapshot_selects: snapshot,
      event_edge_unnest_selects: edge,
      unexpected_interactive_selects: unexpected,
      raw_source_reads: raw,
      pass: pass,
      edge_sql: if(edge_query, do: edge_query.sql),
      edge_params: if(edge_query, do: edge_query.params)
    }
  end

  defp maybe_explain!(report, _fixture, %{id: "60m_aligned"}, _probe), do: report

  defp maybe_explain!(report, fixture, case_spec, probe) do
    edge_query =
      Enum.find(probe.queries, &String.contains?(String.downcase(&1.sql), "from unnest"))

    if is_nil(edge_query),
      do: raise("REQUIRED EXPLAIN EVIDENCE CANNOT BE PRODUCED for #{case_spec.id}")

    explain =
      UnboxedPostgres.with_connection(fn ->
        Repo.query!(
          "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> edge_query.sql,
          edge_query.params
        ).rows
        |> hd()
        |> hd()
        |> decode_json_plan()
        |> plan_summary()
      end)

    row = Map.merge(%{density: fixture.density, case: case_spec.id}, explain)
    Map.update!(report, :explain_rows, &[row | &1])
  end

  defp decode_json_plan(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json_plan(value), do: value

  defp plan_summary([%{"Plan" => root} | _]), do: plan_summary(root)
  defp plan_summary(%{"Plan" => root}), do: plan_summary(root)

  defp plan_summary(root) do
    nodes = walk_plan(root)

    index_names =
      nodes |> Enum.map(&Map.get(&1, "Index Name")) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    seq_scans =
      Enum.count(
        nodes,
        &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == "analytics_contribution_facts")
      )

    buffers =
      Enum.reduce(nodes, %{}, fn node, acc ->
        node
        |> Enum.filter(fn {key, _} ->
          String.contains?(String.downcase(key), "block") or
            String.contains?(String.downcase(key), "buffer")
        end)
        |> Enum.reduce(acc, fn {key, value}, inner ->
          Map.update(inner, key, value, &(&1 + value))
        end)
      end)

    %{
      node_types: Enum.map(nodes, & &1["Node Type"]),
      index_names: index_names,
      actual_rows: Enum.map(nodes, &Map.get(&1, "Actual Rows")) |> Enum.reject(&is_nil/1),
      rows_removed_by_filter:
        Enum.map(nodes, &Map.get(&1, "Rows Removed by Filter")) |> Enum.reject(&is_nil/1),
      buffers: buffers,
      seq_scan_count: seq_scans,
      required_index: @required_index in index_names,
      pass: @required_index in index_names and seq_scans == 0
    }
  end

  defp walk_plan(%{} = node) do
    [node | Enum.flat_map(Map.get(node, "Plans", []), &walk_plan/1)]
  end

  defp measure_cohort!(fixture, plan, density, case_spec, cohort, telemetry_table) do
    {atomics, max_overlap} = :atomics.new(2, signed: true) |> then(&{&1, &1})
    parent = self()
    task_ref = make_ref()
    per_worker = div(@samples, cohort)

    tasks =
      for worker_index <- 1..cohort do
        Task.async(fn ->
          send(parent, {:d1_ready, task_ref, worker_index, self()})
          receive do: ({:d1_activate, ^task_ref} -> :ok)
          active = :atomics.add_get(atomics, 1, 1)
          update_max!(atomics, active)
          send(parent, {:d1_active, task_ref, worker_index})
          receive do: ({:d1_start, ^task_ref} -> :ok)

          try do
            Enum.map(1..per_worker, fn _ -> measured_call(fixture, plan) end)
          after
            :atomics.sub(atomics, 1, 1)
          end
        end)
      end

    Enum.each(1..cohort, fn _ -> receive_message!({:d1_ready, task_ref, :_, :_}, 30_000) end)
    Enum.each(tasks, &send(&1.pid, {:d1_activate, task_ref}))
    Enum.each(1..cohort, fn _ -> receive_message!({:d1_active, task_ref, :_}, 30_000) end)
    Enum.each(tasks, &send(&1.pid, {:d1_start, task_ref}))

    results = Enum.flat_map(tasks, &Task.await(&1, 120_000))
    observed_max = :atomics.get(max_overlap, 2)

    if observed_max != cohort,
      do: raise("INVALID_MEASUREMENT_SETUP requested=#{cohort} observed=#{observed_max}")

    if length(results) != @samples,
      do: raise("INVALID_MEASUREMENT_SETUP sample count #{length(results)} != #{@samples}")

    rows = Enum.map(results, &sample_query_contract(&1, telemetry_table, case_spec))

    if Enum.any?(rows, & &1.unexpected_exception),
      do: raise("unexpected harness exception in cohort #{cohort}")

    durations = Enum.map(results, & &1.duration_us) |> Enum.sort()
    query_times = rows |> Enum.flat_map(& &1.query_times_us) |> Enum.sort()
    queue_times = rows |> Enum.flat_map(& &1.queue_times_us) |> Enum.sort()
    checkout_waits = Enum.map(results, & &1.checkout_wait_us) |> Enum.sort()
    errors = Enum.count(results, &(&1.classification == "read_error"))
    not_ready = Enum.count(results, &(&1.classification == "not_ready"))
    pool_timeouts = Enum.count(results, &(&1.classification == "pool_timeout"))
    raw_reads = Enum.sum(Enum.map(rows, & &1.raw_source_reads))
    query_contract = Enum.all?(rows, & &1.query_contract_pass)
    edge_cardinalities = Enum.map(results, & &1.edge_result_cardinality) |> Enum.uniq()
    result_cardinality = if edge_cardinalities == [], do: 0, else: hd(edge_cardinalities)
    latency = percentile_latency(durations)
    unexpected_selects = Enum.sum(Enum.map(rows, & &1.unexpected_interactive_selects))

    %{
      density: density,
      case: case_spec.id,
      requested_concurrency: cohort,
      actual_worker_count: cohort,
      max_simultaneous_callers_observed: observed_max,
      db_pool_size: @pool_size,
      sample_count: length(results),
      errors: errors,
      not_ready: not_ready,
      pool_timeouts: pool_timeouts,
      query_contract: if(query_contract, do: "PASS", else: "FAIL"),
      unexpected_interactive_select_count: unexpected_selects,
      raw_source_read_count: raw_reads,
      edge_result_cardinality: result_cardinality,
      edge_result_cardinalities: edge_cardinalities,
      edge_result_cardinality_pass:
        Enum.all?(results, &(&1.edge_result_cardinality == plan.edge_fragment_count)),
      end_to_end: latency,
      repo_interactive_query: percentile_set(query_times),
      repo_queue: percentile_set(queue_times),
      pool_checkout_wait: percentile_set(checkout_waits),
      query_contract_all_samples: query_contract
    }
  end

  defp measured_call(fixture, plan) do
    call_ref = make_ref()
    started = System.monotonic_time(:microsecond)

    outcome =
      try do
        result =
          UnboxedPostgres.with_connection(fn ->
            checkout_wait = System.monotonic_time(:microsecond) - started
            Process.put(:m5_05_d1_call_ref, call_ref)

            try do
              read_transaction(fixture, plan)
            after
              Process.delete(:m5_05_d1_call_ref)
            end
            |> then(&{&1, checkout_wait})
          end)

        {result, nil}
      rescue
        error ->
          if pool_timeout?(error),
            do: {{:pool_timeout, Exception.message(error)}, nil},
            else: {{:unexpected, Exception.message(error)}, nil}
      end

    duration = System.monotonic_time(:microsecond) - started

    {result, checkout_wait} =
      case outcome do
        {{value, wait}, nil} -> {value, wait}
        {{:pool_timeout, reason}, nil} -> {{:pool_timeout, reason}, duration}
        {{:unexpected, reason}, nil} -> {{:unexpected, reason}, duration}
      end

    %{
      call_ref: call_ref,
      duration_us: duration,
      checkout_wait_us: checkout_wait,
      result: result,
      classification: classify_result(result),
      edge_result_cardinality: edge_cardinality(result)
    }
  end

  defp sample_query_contract(sample, telemetry_table, case_spec) do
    queries =
      case :ets.lookup(telemetry_table, sample.call_ref) do
        [] when sample.classification == "ready" ->
          raise("per-call telemetry missing for ready read #{inspect(sample.call_ref)}")

        records ->
          Enum.map(records, &elem(&1, 1))
      end

    interactive = Enum.filter(queries, &interactive_query?/1)
    shape = query_shape(queries, case_spec)
    expected = if case_spec.id == "60m_aligned", do: 1, else: 2
    per_read = length(interactive) == expected

    %{
      query_times_us: Enum.map(interactive, & &1.query_time_us),
      queue_times_us: Enum.map(interactive, & &1.queue_time_us),
      raw_source_reads: shape.raw_source_reads,
      unexpected_interactive_selects: shape.unexpected_interactive_selects,
      query_contract_pass: per_read and shape.pass and shape.raw_source_reads == 0,
      unexpected_exception: sample.classification == "unexpected_harness_exception"
    }
  end

  defp read_once(fixture, plan, call_ref) do
    checkout_started = System.monotonic_time(:microsecond)

    result =
      UnboxedPostgres.with_connection(fn ->
        checkout_wait = System.monotonic_time(:microsecond) - checkout_started
        if call_ref, do: Process.put(:m5_05_d1_call_ref, call_ref)

        try do
          {read_transaction(fixture, plan), checkout_wait}
        after
          if call_ref, do: Process.delete(:m5_05_d1_call_ref)
        end
      end)

    %{result: elem(result, 0), checkout_wait_us: elem(result, 1), call_ref: call_ref}
  end

  defp read_transaction(fixture, plan) do
    opts = [timeout: 120_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

    Repo.transaction(
      fn ->
        :ok = EventSnapshotRefreshFence.prepare_coherent_transaction!()
        ProjectionPeriodReader.read(fixture.event.id, "ZAR", plan)
      end,
      opts
    )
  end

  defp assert_ready_result!({:ok, {:ok, projection}}, plan) do
    if projection.current_operand.readiness != :ready or
         projection.previous_operand.readiness != :ready,
       do: raise("fixture projection is not ready")

    if map_size(projection.event_edges) != plan.edge_fragment_count,
      do:
        raise(
          "edge result cardinality #{map_size(projection.event_edges)} != #{plan.edge_fragment_count}"
        )

    :ok
  end

  defp assert_ready_result!(result, _plan),
    do: raise("warmup/probe read failed: #{inspect(result)}")

  defp classify_result({:pool_timeout, _}), do: "pool_timeout"
  defp classify_result({:unexpected, _}), do: "unexpected_harness_exception"

  defp classify_result({:ok, {:ok, projection}}) do
    if projection.current_operand.readiness == :ready and
         projection.previous_operand.readiness == :ready,
       do: "ready",
       else: "not_ready"
  end

  defp classify_result({:ok, {:error, _}}), do: "read_error"
  defp classify_result({:error, _}), do: "read_error"
  defp classify_result(_), do: "read_error"

  defp edge_cardinality({:ok, {:ok, projection}}), do: map_size(projection.event_edges)
  defp edge_cardinality(_), do: 0

  defp pool_timeout?(error) do
    message = Exception.message(error) |> String.downcase()
    String.contains?(message, "timeout") or String.contains?(message, "queue")
  end

  defp queries_for_call!(table, call_ref) do
    records = :ets.lookup(table, call_ref) |> Enum.map(&elem(&1, 1))
    if records == [], do: raise("per-call telemetry missing for #{inspect(call_ref)}")
    records
  end

  defp attach_telemetry!(handler_id, table) do
    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, measurements, metadata, _config ->
          case Process.get(:m5_05_d1_call_ref) do
            nil ->
              :ok

            call_ref ->
              :ets.insert(
                table,
                {call_ref,
                 %{
                   sql: metadata[:query] || "",
                   params: metadata[:params] || [],
                   query_time_us: native_us(measurements[:query_time]),
                   queue_time_us: native_us(measurements[:queue_time]),
                   caller: self()
                 }}
              )
          end
        end,
        nil
      )
  end

  defp interactive_query?(query) do
    sql = String.trim_leading(query.sql) |> String.upcase()
    String.starts_with?(sql, "SELECT") or String.starts_with?(sql, "WITH")
  end

  defp raw_source_read?(sql) do
    normalized = String.downcase(sql)

    Enum.any?(
      ["sales_orders", "sales_order_items", "sales_refunds", "sales_refund_lines"],
      &String.contains?(normalized, &1)
    )
  end

  defp native_us(nil), do: 0
  defp native_us(value), do: System.convert_time_unit(value, :native, :microsecond)

  defp update_max!(atomics, value) do
    current = :atomics.get(atomics, 2)

    if value > current do
      case :atomics.compare_exchange(atomics, 2, current, value) do
        :ok -> :ok
        _actual -> update_max!(atomics, value)
      end
    end
  end

  defp receive_message!({tag, ref, _, _}, timeout) do
    receive do
      {^tag, ^ref, _index, _pid} -> :ok
    after
      timeout -> raise("INVALID_MEASUREMENT_SETUP timed out waiting for #{tag}")
    end
  end

  defp receive_message!({tag, ref, _}, timeout) do
    receive do
      {^tag, ^ref, _index} -> :ok
    after
      timeout -> raise("INVALID_MEASUREMENT_SETUP timed out waiting for #{tag}")
    end
  end

  defp percentile_set(sorted) do
    %{
      p50_us: percentile(sorted, 50),
      p95_us: percentile(sorted, 95),
      p99_us: percentile(sorted, 99),
      max_us: List.last(sorted) || 0
    }
  end

  defp percentile_latency(sorted) do
    values = percentile_set(sorted)

    values
    |> Map.merge(%{
      p50_ms: values.p50_us / 1_000,
      p95_ms: values.p95_us / 1_000,
      p99_ms: values.p99_us / 1_000,
      max_ms: values.max_us / 1_000
    })
  end

  defp percentile([], _percent), do: 0

  defp percentile(sorted, percent),
    do: Enum.at(sorted, round(percent / 100 * (length(sorted) - 1)))

  defp finalize_report(report) do
    rows = Enum.reverse(report.measurement_rows)
    explain_rows = Enum.reverse(report.explain_rows)
    shape_rows = Enum.reverse(report.query_shape_rows)
    query_shape_pass = length(shape_rows) == 8 and Enum.all?(shape_rows, & &1.pass)
    index_pass = length(explain_rows) == 6 and Enum.all?(explain_rows, & &1.pass)
    seq_count = Enum.sum(Enum.map(explain_rows, & &1.seq_scan_count))

    raw_reads =
      Enum.sum(Enum.map(rows, & &1.raw_source_read_count)) +
        Enum.sum(Enum.map(shape_rows, & &1.raw_source_reads))

    pool_timeouts = Enum.sum(Enum.map(rows, & &1.pool_timeouts))

    rows_valid =
      length(rows) == 24 and
        Enum.all?(
          rows,
          &(&1.sample_count == @samples and &1.actual_worker_count == &1.requested_concurrency and
              &1.max_simultaneous_callers_observed == &1.requested_concurrency)
        )

    normal_pass =
      Enum.all?(
        Enum.filter(rows, &(&1.density == :normal and &1.requested_concurrency == 50)),
        &(&1.end_to_end.p99_us <= @normal_limit_us)
      )

    high_pass =
      Enum.all?(
        Enum.filter(rows, &(&1.density == :high_density and &1.requested_concurrency == 50)),
        &(&1.end_to_end.p99_us <= @high_limit_us)
      )

    quality =
      Enum.all?(
        rows,
        &(&1.errors == 0 and &1.not_ready == 0 and &1.pool_timeouts == 0 and
            &1.query_contract == "PASS" and &1.raw_source_read_count == 0 and
            &1.edge_result_cardinality_pass)
      )

    go =
      rows_valid and query_shape_pass and index_pass and raw_reads == 0 and pool_timeouts == 0 and
        quality and normal_pass and high_pass

    report
    |> Map.put(:measurement_rows, rows)
    |> Map.put(:explain_rows, explain_rows)
    |> Map.put(:query_shape_rows, shape_rows)
    |> Map.put(:query_shape_pass, query_shape_pass)
    |> Map.put(:index_selectivity_pass, index_pass)
    |> Map.put(:seq_scan_count, seq_count)
    |> Map.put(:raw_source_reads, raw_reads)
    |> Map.put(:pool_timeouts, pool_timeouts)
    |> Map.put(:normal_c50_gate, if(normal_pass, do: "PASS", else: "FAIL"))
    |> Map.put(:high_density_c50_gate, if(high_pass, do: "PASS", else: "FAIL"))
    |> Map.put(
      :measurement_valid,
      rows_valid and length(explain_rows) == 6 and length(shape_rows) == 8
    )
    |> Map.put(:preliminary_option_a, if(go, do: "GO", else: "NO_GO"))
  end

  defp head_identity do
    %{head_sha: git!("rev-parse", "HEAD"), head_tree: git!("rev-parse", "HEAD^{tree}")}
  end

  defp git!(arg1, arg2) do
    {output, 0} = System.cmd("git", [arg1, arg2], stderr_to_stdout: true)
    String.trim(output)
  end

  defp write_evidence!(report) do
    File.mkdir_p!(Path.dirname(@evidence_path))
    File.write!(@evidence_path, Jason.encode!(report, pretty: true) <> "\n")
  end

  defp prior_invalid_attempts! do
    if File.exists?(@evidence_path) do
      previous = Jason.decode!(File.read!(@evidence_path))

      if previous["measurement_valid"] == true,
        do: raise("valid D1 evidence already exists; reruns are prohibited")

      Map.get(previous, "prior_invalid_attempts", []) ++
        [
          %{
            head_sha: previous["head_sha"],
            head_tree: previous["head_tree"],
            invalid_reason: previous["invalid_reason"],
            measurement_rows: length(previous["measurement_rows"] || [])
          }
        ]
    else
      []
    end
  end

  defp print_summary(report) do
    IO.puts("M5_05D1_BASE_SHA=#{@base_sha}")
    IO.puts("M5_05D1_HEAD_SHA=#{report.head_sha}")
    IO.puts("MEASUREMENT_VALID=#{if report.measurement_valid, do: "YES", else: "NO"}")
    IO.puts("DB_POOL_SIZE=#{@pool_size}")
    IO.puts("CONCURRENCY_COHORTS=1,20,50")
    IO.puts("MEASUREMENT_ROWS=#{length(report.measurement_rows)}")
    IO.puts("EXPLAIN_ROWS=#{length(report.explain_rows)}")
    IO.puts("QUERY_SHAPE_PASS=#{Map.get(report, :query_shape_pass, false)}")
    IO.puts("INDEX_SELECTIVITY_PASS=#{Map.get(report, :index_selectivity_pass, false)}")
    IO.puts("RAW_SOURCE_READS=#{Map.get(report, :raw_source_reads, 0)}")
    IO.puts("POOL_TIMEOUTS=#{Map.get(report, :pool_timeouts, 0)}")
    IO.puts("NORMAL_C50_P99_GATE=#{Map.get(report, :normal_c50_gate, "NOT_EVALUATED")}")

    IO.puts(
      "HIGH_DENSITY_C50_P99_GATE=#{Map.get(report, :high_density_c50_gate, "NOT_EVALUATED")}"
    )

    IO.puts("PRELIMINARY_OPTION_A=#{Map.get(report, :preliminary_option_a, "NOT_EVALUATED")}")
    IO.puts("EVIDENCE_PATH=#{@evidence_path}")
    Enum.each(report.measurement_rows, &IO.puts("MEASUREMENT_ROW=#{Jason.encode!(&1)}"))
    Enum.each(report.explain_rows, &IO.puts("EXPLAIN_ROW=#{Jason.encode!(&1)}"))
    if reason = Map.get(report, :invalid_reason), do: IO.puts("INVALID_REASON=#{reason}")
  end

  defp uuid_binary!(uuid), do: Ecto.UUID.dump!(uuid)
end
