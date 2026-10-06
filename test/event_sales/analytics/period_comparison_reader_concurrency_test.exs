defmodule EventSales.Analytics.PeriodComparisonReaderConcurrencyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.UnboxedPostgres

  @now ~U[2026-05-17 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period concurrency"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_user!("period-concurrency-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 3, gross_ticket_value: Decimal.new("30.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    %{event: event, admin: admin}
  end

  test "stale required bucket returns comparison_missing in the public envelope", %{
    event: event,
    admin: admin
  } do
    import Ecto.Query

    from(row in EventPeriodAggregateSnapshot,
      where: row.event_id == ^event.id and row.projection_state == :current
    )
    |> order_by([row], asc: row.bucket_start_utc)
    |> limit(1)
    |> Repo.one!()
    |> then(fn row ->
      Repo.update_all(
        from(b in EventPeriodAggregateSnapshot, where: b.id == ^row.id),
        set: [projection_state: :stale]
      )
    end)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: admin,
               now: @now
             )

    assert result.current.readiness in [:ready, :not_ready]
    assert result.comparison.readiness in [:ready, :not_ready]

    state = result.event.metric_comparisons.gross_ticket_quantity.state
    assert state in [:current_missing, :comparison_missing]
  end

  test "production coherent transaction establishes repeatable read before projection statements" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "RR isolation probe"})
      on_exit(fn -> cleanup_unboxed_period_fixture!(event.id, source.id) end)
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

      PeriodComparisonHelpers.seed_comparison_projection!(
        event,
        source,
        ticket,
        "ZAR",
        :yesterday,
        @now,
        %{
          current: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")},
          previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
        }
      )

      {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:yesterday, @now)

      transaction_opts =
        [timeout: 30_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

      assert {:ok, isolation} =
               UnboxedPostgres.with_connection(fn ->
                 Repo.transaction(
                   fn ->
                     PeriodComparisonReader.load_operand_payload_for_test!(
                       event.id,
                       "ZAR",
                       plan
                     )

                     %Postgrex.Result{rows: [[level]]} =
                       Repo.query!("SELECT current_setting('transaction_isolation')")

                     level
                   end,
                   transaction_opts
                 )
               end)

      assert String.downcase(isolation) == "repeatable read"
    end)
  end

  test "coherent_transaction_opts alone does not establish repeatable read on Postgrex" do
    UnboxedPostgres.with_connection(fn ->
      assert EventSnapshotRefreshFence.use_repeatable_read_isolation?()

      transaction_opts =
        [timeout: 30_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

      assert {:ok, isolation} =
               Repo.transaction(
                 fn ->
                   %Postgrex.Result{rows: [[level]]} =
                     Repo.query!("SELECT current_setting('transaction_isolation')")

                   level
                 end,
                 transaction_opts
               )

      assert String.downcase(isolation) == "read committed"
    end)
  end

  test "repeatable read transaction keeps one snapshot across an interleaved writer commit" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "RR period comparison"})
      on_exit(fn -> cleanup_unboxed_period_fixture!(event.id, source.id) end)
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

      PeriodComparisonHelpers.seed_comparison_projection!(
        event,
        source,
        ticket,
        "ZAR",
        :yesterday,
        @now,
        %{
          current: %{gross_ticket_quantity: 3, gross_ticket_value: Decimal.new("30.00")},
          previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
        }
      )

      {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:yesterday, @now)
      reader = self()

      writer =
        Task.async(fn ->
          receive do
            {:reader_first_read_done, row_id} ->
              UnboxedPostgres.with_connection(fn ->
                Repo.update_all(
                  from(b in EventPeriodAggregateSnapshot, where: b.id == ^row_id),
                  set: [
                    gross_ticket_quantity: 9_999,
                    generation_id: Ecto.UUID.generate()
                  ]
                )

                send(reader, :writer_committed)
              end)
          after
            15_000 -> raise "writer never received reader signal"
          end
        end)

      transaction_opts =
        [timeout: 30_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

      assert {:ok, snapshot_gross} =
               UnboxedPostgres.with_connection(fn ->
                 Repo.transaction(
                   fn ->
                     assert EventSnapshotRefreshFence.use_repeatable_read_isolation?()

                     first_payload =
                       PeriodComparisonReader.load_operand_payload_for_test!(
                         event.id,
                         "ZAR",
                         plan
                       )

                     first_gross = sum_event_row_gross(first_payload)
                     assert first_gross > 0

                     row =
                       from(b in EventPeriodAggregateSnapshot,
                         where: b.event_id == ^event.id and b.projection_state == :current,
                         order_by: [asc: b.bucket_start_utc],
                         limit: 1
                       )
                       |> Repo.one!()

                     send(writer.pid, {:reader_first_read_done, row.id})

                     receive do
                       :writer_committed -> :ok
                     after
                       15_000 -> Repo.rollback(:writer_timeout)
                     end

                     second_payload =
                       PeriodComparisonReader.load_operand_payload_for_test!(
                         event.id,
                         "ZAR",
                         plan
                       )

                     second_gross = sum_event_row_gross(second_payload)
                     assert first_gross == second_gross
                     first_gross
                   end,
                   transaction_opts
                 )
               end)

      assert Task.await(writer, 15_000)

      outside_payload =
        PeriodComparisonReader.load_operand_payload_for_test!(event.id, "ZAR", plan)

      assert sum_event_row_gross(outside_payload) > snapshot_gross
    end)
  end

  defp sum_event_row_gross(payload) do
    payload.event_rows
    |> Enum.map(& &1.gross_ticket_quantity)
    |> Enum.sum()
  end

  defp cleanup_unboxed_period_fixture!(event_id, source_id) do
    import Ecto.Query

    alias EventSales.Analytics.Resources.{
      AnalyticsContributionFact,
      EventDimensionPeriodAggregateSnapshot,
      EventPeriodAggregateSnapshot
    }

    alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
    UnboxedPostgres.with_connection(fn ->
      Repo.delete_all(from(f in AnalyticsContributionFact, where: f.event_id == ^event_id))

      Repo.delete_all(
        from(s in EventDimensionPeriodAggregateSnapshot, where: s.event_id == ^event_id)
      )

      Repo.delete_all(from(s in EventPeriodAggregateSnapshot, where: s.event_id == ^event_id))
      Repo.delete_all(from(t in TicketType, where: t.event_id == ^event_id))
      Repo.delete_all(from(e in Event, where: e.id == ^event_id))
      Repo.delete_all(from(s in SourceSystem, where: s.id == ^source_id))
    end)
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Concurrency User",
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
