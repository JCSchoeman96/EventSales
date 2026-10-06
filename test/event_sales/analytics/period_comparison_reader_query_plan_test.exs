defmodule EventSales.Analytics.PeriodComparisonReaderQueryPlanTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:17:33.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period query plan"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_user!("period-query-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    %{
      source: source,
      event: event,
      ticket: ticket,
      admin: admin
    }
  end

  test "yesterday read uses five fixed projection selects and no edge aggregates", ctx do
    seed_yesterday!(ctx)

    assert {:ok, _} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    {_result, queries} =
      capture_sql(fn ->
        PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
          actor: ctx.admin,
          now: @now
        )
      end)

    selects = select_queries(queries)

    projection_selects =
      Enum.filter(selects, fn sql ->
        String.contains?(sql, "analytics_event_period_aggregate_snapshots") or
          String.contains?(sql, "analytics_event_dimension_period_aggregate_snapshots")
      end)

    assert length(projection_selects) == 5
    refute Enum.any?(selects, &String.contains?(&1, "unnest"))
  end

  test "elapsed today read adds bounded edge aggregate queries", ctx do
    seed_today_with_edges!(ctx)

    {result, queries} =
      capture_sql(fn ->
        PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
          actor: ctx.admin,
          now: @now
        )
      end)

    assert {:ok, _} = result

    selects = select_queries(queries)
    unnest_queries = Enum.filter(selects, &String.contains?(&1, "unnest"))

    projection_selects =
      Enum.filter(selects, fn sql ->
        String.contains?(sql, "analytics_event_period_aggregate_snapshots") or
          String.contains?(sql, "analytics_event_dimension_period_aggregate_snapshots")
      end)

    assert length(projection_selects) == 5
    assert length(unnest_queries) == 5
  end

  test "edge unnest aggregate exposes metadata mismatch counts and explain is selective", ctx do
    seed_today_with_edges!(ctx)

    other_source = SalesHelpers.create_source_system!()
    other_event = SalesHelpers.create_event!(other_source, %{name: "Noise event"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Noise ticket"})
    EventDetailCertificationHelpers.certify_analytics_ready!(other_event)

    seed_contribution_noise!(ctx, other_event.id, other_source.id, other_ticket.id)

    {_result, queries} =
      capture_sql(fn ->
        PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :today,
          actor: ctx.admin,
          now: @now
        )
      end)

    {edge_sql, edge_params} =
      Enum.find(queries, fn {sql, _params} ->
        String.contains?(sql, "metadata_mismatch_count") and String.contains?(sql, "unnest")
      end)

    {:ok, edge_result} = EventSales.Repo.query(edge_sql, edge_params)
    assert edge_result.num_rows > 0
    assert Enum.all?(edge_result.rows, fn row -> List.last(row) == 0 end)

    {:ok, _} = EventSales.Repo.query("ANALYZE analytics_contribution_facts")

    {:ok, %{rows: [[plan_json]]}} =
      EventSales.Repo.query("EXPLAIN (FORMAT JSON) " <> edge_sql, edge_params)

    plan = normalize_explain_plan(plan_json)
    encoded = Jason.encode!(plan)

    assert String.contains?(encoded, "analytics_contribution_facts")
    assert contribution_scan_scoped_to_event_and_time?(plan)

    refute sequential_scan_on_contribution_facts?(plan)
  end

  defp seed_contribution_noise!(ctx, other_event_id, other_source_id, other_ticket_id) do
    alias EventSales.Analytics.Resources.AnalyticsContributionFact

    noise_fact = fn attrs ->
      Ash.create!(
        AnalyticsContributionFact,
        Map.merge(
          %{
            contribution_kind: :sale,
            source_contribution_id: Ecto.UUID.generate(),
            ticket_type_id: ctx.ticket.id,
            source_system_id: ctx.source.id,
            woo_product_id: 90_000,
            woo_variation_id: nil,
            gross_ticket_quantity: 1,
            gross_ticket_value: Decimal.new("9.99"),
            refund_ticket_quantity: 0,
            refund_ticket_value: Decimal.new("0"),
            generation_id: Ecto.UUID.generate(),
            semantic_version: 1,
            coverage_identity: "noise_coverage",
            refreshed_at: @now
          },
          attrs
        ),
        action: :create_fact,
        domain: EventSales.Analytics
      )
    end

    for idx <- 1..150 do
      noise_fact.(%{
        event_id: other_event_id,
        currency: "ZAR",
        effective_at: DateTime.add(@now, -idx, :minute),
        ticket_type_id: other_ticket_id,
        source_system_id: other_source_id
      })
    end

    for idx <- 1..150 do
      noise_fact.(%{
        event_id: ctx.event.id,
        currency: "USD",
        effective_at: DateTime.add(@now, -idx, :minute)
      })
    end

    for idx <- 1..150 do
      noise_fact.(%{
        event_id: ctx.event.id,
        currency: "ZAR",
        effective_at: DateTime.add(@now, -7, :day) |> DateTime.add(-idx, :minute)
      })
    end

    for idx <- 1..150 do
      noise_fact.(%{
        event_id: other_event_id,
        currency: "EUR",
        effective_at: DateTime.add(@now, -idx, :minute),
        ticket_type_id: other_ticket_id,
        source_system_id: other_source_id
      })
    end
  end

  defp normalize_explain_plan(plan_json) do
    case plan_json do
      plan when is_map(plan) -> plan
      plan when is_binary(plan) -> Jason.decode!(plan)
      [plan] when is_map(plan) -> plan
    end
  end

  defp contribution_scan_scoped_to_event_and_time?(plan) when is_map(plan) do
    plan_node_scoped?(Map.get(plan, "Plan", plan)) or
      Enum.any?(Map.get(plan, "Plans", []), &plan_node_scoped?/1)
  end

  defp contribution_scan_scoped_to_event_and_time?(_), do: false

  defp plan_node_scoped?(%{"Plans" => children}) when is_list(children) do
    Enum.any?(children, &plan_node_scoped?/1)
  end

  defp plan_node_scoped?(%{"Plan" => child}), do: plan_node_scoped?(child)

  defp plan_node_scoped?(
         %{"Node Type" => type, "Relation Name" => "analytics_contribution_facts"} =
           node
       )
       when type in ["Seq Scan", "Index Scan", "Bitmap Heap Scan", "Index Only Scan"] do
    qual =
      [
        Map.get(node, "Filter"),
        Map.get(node, "Index Cond"),
        Map.get(node, "Recheck Cond"),
        Map.get(node, "Join Filter")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    String.contains?(qual, "event_id") and
      (String.contains?(qual, "effective_at") or String.contains?(qual, "currency"))
  end

  defp plan_node_scoped?(%{"Plans" => _} = node), do: plan_node_scoped?(Map.drop(node, ["Plans"]))

  defp plan_node_scoped?(_), do: false

  defp sequential_scan_on_contribution_facts?(plan) when is_list(plan) do
    plan
    |> Jason.encode!()
    |> String.contains?("Seq Scan on analytics_contribution_facts")
  end

  defp sequential_scan_on_contribution_facts?(%{"Plan" => child}),
    do: sequential_scan_on_contribution_facts?(child)

  defp sequential_scan_on_contribution_facts?(%{"Plans" => children}) when is_list(children) do
    Enum.any?(children, &sequential_scan_on_contribution_facts?/1)
  end

  defp sequential_scan_on_contribution_facts?(_), do: false

  defp seed_yesterday!(ctx) do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 4, gross_ticket_value: Decimal.new("40.00")},
        previous: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")}
      }
    )
  end

  defp seed_today_with_edges!(ctx) do
    PeriodComparisonHelpers.seed_comparison_projection!(
      ctx.event,
      ctx.source,
      ctx.ticket,
      "ZAR",
      :today,
      @now,
      %{
        current: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: %{
            default: [%{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")}]
          }
        },
        previous: %{
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          edge_facts: %{
            default: [%{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}]
          }
        }
      }
    )
  end

  defp _classify_queries(queries) do
    selects = select_queries(queries)

    dimension_selects =
      Enum.filter(
        selects,
        &String.contains?(&1, "analytics_event_dimension_period_aggregate_snapshots")
      )

    dimension_interiors =
      Enum.count(dimension_selects, &Regex.match?(~r/"dimension_kind"\s*=/, &1))

    dimension_coverage = length(dimension_selects) - dimension_interiors

    event_selects =
      Enum.filter(selects, &String.contains?(&1, "analytics_event_period_aggregate_snapshots"))

    contribution_selects =
      Enum.filter(selects, &String.contains?(&1, "analytics_contribution_facts"))

    %{
      event_buckets: length(event_selects),
      dimension_coverage: dimension_coverage,
      dimension_interiors: dimension_interiors,
      event_edges:
        Enum.count(contribution_selects, fn sql ->
          String.contains?(sql, "unnest") and not Regex.match?(~r/"dimension_kind"\s*=/, sql)
        end),
      dimension_edges:
        Enum.count(contribution_selects, fn sql ->
          String.contains?(sql, "unnest") and Regex.match?(~r/"dimension_kind"\s*=/, sql)
        end),
      total_selects: length(selects)
    }
  end

  defp select_queries(queries) do
    Enum.map(queries, fn {sql, _params} -> sql end)
    |> Enum.filter(&String.match?(&1, ~r/^\s*(select|with)\b/i))
  end

  defp capture_sql(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        EventSales.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, metadata.query, metadata.params})
        end,
        {parent, handler_id}
      )

    try do
      result = fun.()
      {result, collect_sql(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_sql(handler_id, acc) do
    receive do
      {^handler_id, sql, params} -> collect_sql(handler_id, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Query User",
        password: "valid-pass-123",
        password_confirmation: "valid-pass-123"
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end
end
