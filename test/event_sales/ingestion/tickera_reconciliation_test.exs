defmodule EventSales.Ingestion.TickeraReconciliationTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion

  alias EventSales.Ingestion.{
    TickeraAttendeeSnapshots,
    TickeraAttendeeSyncRuns,
    TickeraEventSources,
    TickeraReconciliation,
    TickeraReconciliationFindings,
    TickeraReconciliationRuns
  }

  alias EventSales.Ingestion.Resources.TickeraReconciliationFinding
  alias EventSales.Sales
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("tickera-reconciliation-admin@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Reconciliation",
        slug: unique_slug("tickera-reconciliation")
      })

    ticket_type = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECONCILIATION"
        },
        actor: admin
      )

    {:ok, sync_run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)
    {:ok, started_sync_run} = TickeraAttendeeSyncRuns.mark_started(sync_run, internal?: true)

    {:ok, completed_sync_run} =
      TickeraAttendeeSyncRuns.mark_completed(started_sync_run, internal?: true)

    {:ok,
     admin: admin,
     source_system: source_system,
     event: event,
     ticket_type: ticket_type,
     source: source,
     sync_run: completed_sync_run}
  end

  test "completed Woo count equals Tickera paid count creates no critical finding", context do
    create_order_with_item!(context, %{quantity: 2, status: :completed})
    create_snapshot!(context, %{ticket_code: "EQUAL-1", ticket_type: "General Admission"})
    create_snapshot!(context, %{ticket_code: "EQUAL-2", ticket_type: "General Admission"})

    run = queue_run!(context)

    assert {:ok, completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])
    assert completed.status == :completed

    assert {:ok, findings} = TickeraReconciliationFindings.list_for_run(run.id, internal?: true)
    refute Enum.any?(findings, &(&1.severity == :critical))
  end

  test "Woo completed greater than Tickera paid creates missing and mismatch findings", context do
    create_order_with_item!(context, %{quantity: 2, status: :completed})
    create_snapshot!(context, %{ticket_code: "MISSING-1", ticket_type: "General Admission"})

    run = queue_run!(context)

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    findings = findings_for_run!(run)
    assert finding(findings, :woo_paid_missing_tickera).severity == :critical
    assert finding(findings, :quantity_mismatch).severity == :critical
  end

  test "Tickera paid greater than Woo completed creates extra warning", context do
    create_order_with_item!(context, %{quantity: 1, status: :completed})
    create_snapshot!(context, %{ticket_code: "EXTRA-1", ticket_type: "General Admission"})
    create_snapshot!(context, %{ticket_code: "EXTRA-2", ticket_type: "General Admission"})

    run = queue_run!(context)

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    assert finding(findings_for_run!(run), :tickera_paid_extra).severity == :warning
  end

  test "Woo refunded or cancelled with Tickera paid creates payment status mismatch", context do
    create_order_with_item!(context, %{quantity: 1, status: :refunded})
    create_snapshot!(context, %{ticket_code: "STATUS-1", ticket_type: "General Admission"})

    run = queue_run!(context)

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    assert finding(findings_for_run!(run), :payment_status_mismatch).severity == :warning
  end

  test "unmapped Woo ticket item creates info finding", context do
    create_unmapped_item!(context)
    run = queue_run!(context)

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    assert finding(findings_for_run!(run), :unmapped_woo_order_item).severity == :info
  end

  test "no active Tickera source creates no_tickera_source finding", context do
    create_order_with_item!(context, %{quantity: 1, status: :completed})
    {:ok, _source} = TickeraEventSources.deactivate_source(context.source, actor: context.admin)

    {:ok, %{reconciliation_run: run}} =
      TickeraReconciliationRuns.queue_manual_for_event(context.event.id,
        actor: context.admin,
        oban_insert: fake_oban_insert()
      )

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    no_source = finding(findings_for_run!(run), :no_tickera_source)
    assert no_source.severity == :info
    assert no_source.source_scope_key == "no_source:" <> context.event.id
  end

  test "active source with no snapshots creates no_tickera_snapshots finding", context do
    create_order_with_item!(context, %{quantity: 1, status: :completed})
    run = queue_run!(context)

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    assert finding(findings_for_run!(run), :no_tickera_snapshots).severity == :info
  end

  test "stale snapshots create stale_tickera_snapshot warning", context do
    create_order_with_item!(context, %{quantity: 1, status: :completed})

    create_snapshot!(context, %{
      ticket_code: "STALE-1",
      ticket_type: "General Admission",
      last_seen_at: ~U[2026-05-17 10:00:00Z]
    })

    run = queue_run!(context)

    assert {:ok, _completed} =
             TickeraReconciliation.run(run,
               now: ~U[2026-05-19 12:00:00Z],
               stale_snapshot_after_hours: 24
             )

    assert finding(findings_for_run!(run), :stale_tickera_snapshot).severity == :warning
  end

  test "unknown Tickera ticket label creates mismatch and keeps external ticket type id in details",
       context do
    create_order_with_item!(context, %{quantity: 1, status: :completed})

    create_snapshot!(context, %{
      ticket_code: "UNKNOWN-1",
      ticket_type: "Human Renamed Ticket",
      ticket_type_id: 999
    })

    run = queue_run!(context)

    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    mismatch = finding(findings_for_run!(run), :ticket_type_mismatch)
    assert mismatch.ticket_type_id == nil
    assert mismatch.details["tickera_ticket_type_id"] == 999
  end

  test "repeated reconciliation updates existing finding without duplicating", context do
    create_order_with_item!(context, %{quantity: 2, status: :completed})
    create_snapshot!(context, %{ticket_code: "REPEAT-1", ticket_type: "General Admission"})

    first_run = queue_run!(context)
    second_run = queue_run!(context)

    assert {:ok, _completed} =
             TickeraReconciliation.run(first_run, now: ~U[2026-05-19 12:00:00Z])

    assert {:ok, _completed} =
             TickeraReconciliation.run(second_run, now: ~U[2026-05-19 12:05:00Z])

    assert Ash.count!(TickeraReconciliationFinding, domain: Ingestion) == 2

    missing =
      TickeraReconciliationFinding
      |> Ash.Query.filter(finding_type == :woo_paid_missing_tickera)
      |> Ash.read_one!(domain: Ingestion)

    assert missing.tickera_reconciliation_run_id == second_run.id
  end

  test "old open findings are not auto-resolved", context do
    old_run = queue_run!(context)

    {:ok, old_finding} =
      TickeraReconciliationFindings.upsert_open(
        %{
          tickera_reconciliation_run_id: old_run.id,
          tickera_event_source_id: context.source.id,
          source_system_id: context.source_system.id,
          event_id: context.event.id,
          finding_type: :woo_paid_missing_tickera,
          severity: :critical,
          details: %{},
          fingerprint: "old-open-finding",
          first_seen_at: ~U[2026-05-19 10:00:00Z],
          last_seen_at: ~U[2026-05-19 10:00:00Z]
        },
        internal?: true
      )

    create_order_with_item!(context, %{quantity: 1, status: :completed})

    create_snapshot!(context, %{
      ticket_code: "RESOLVED-BUT-OPEN",
      ticket_type: "General Admission"
    })

    run = queue_run!(context)
    assert {:ok, _completed} = TickeraReconciliation.run(run, now: ~U[2026-05-19 12:00:00Z])

    reloaded = Ash.get!(TickeraReconciliationFinding, old_finding.id, domain: Ingestion)
    assert reloaded.status == :open
  end

  test "forced exception marks run failed and returns error", context do
    original_raise = Application.get_env(:event_sales, :tickera_reconciliation_test_raise)

    on_exit(fn ->
      restore_test_raise!(original_raise)
    end)

    Application.put_env(
      :event_sales,
      :tickera_reconciliation_test_raise,
      "forced reconciliation failure"
    )

    run = queue_run!(context)

    assert {:error, {:failed, failed, :exception}} = TickeraReconciliation.run(run)
    assert failed.status == :failed
    assert failed.last_error =~ "forced reconciliation failure"
    assert String.length(failed.last_error) <= 500
  end

  defp queue_run!(context) do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(context.source, %{}, actor: context.admin)
    run
  end

  defp create_order_with_item!(context, attrs) do
    order =
      Ash.create!(
        Order,
        %{
          source_system_id: context.source_system.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "R-#{System.unique_integer([:positive])}",
          status: Map.fetch!(attrs, :status),
          currency: "ZAR",
          completed_at: ~U[2026-05-19 09:00:00Z],
          created_at_source: ~U[2026-05-19 08:00:00Z],
          updated_at_source: ~U[2026-05-19 09:00:00Z],
          raw_total: Decimal.new("100.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => System.unique_integer([:positive]),
      "variation_id" => nil,
      "name" => "General Admission",
      "quantity" => Map.fetch!(attrs, :quantity),
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0"
    }

    SalesHelpers.create_order_item_from_line!(order, line, %{
      event_id: context.event.id,
      ticket_type_id: context.ticket_type.id,
      mapping_status: :mapped,
      item_kind: :ticket
    })
  end

  defp create_unmapped_item!(context) do
    order =
      Ash.create!(
        Order,
        %{
          source_system_id: context.source_system.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "U-#{System.unique_integer([:positive])}",
          status: :completed,
          currency: "ZAR",
          completed_at: ~U[2026-05-19 09:00:00Z],
          created_at_source: ~U[2026-05-19 08:00:00Z],
          updated_at_source: ~U[2026-05-19 09:00:00Z],
          raw_total: Decimal.new("100.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => System.unique_integer([:positive]),
      "variation_id" => nil,
      "name" => "Needs Mapping",
      "quantity" => 1,
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0"
    }

    SalesHelpers.create_order_item_from_line!(order, line, %{
      event_id: context.event.id,
      mapping_status: :unmapped,
      item_kind: :ticket
    })
  end

  defp create_snapshot!(context, overrides) do
    attrs =
      %{
        tickera_event_source_id: context.source.id,
        tickera_attendee_sync_run_id: context.sync_run.id,
        ticket_code: "TICKET-#{System.unique_integer([:positive])}",
        checksum: "CHECK-#{System.unique_integer([:positive])}",
        ticket_type_id: 123,
        ticket_type: "General Admission",
        first_name: "Jan",
        last_name: "Smit",
        email: "jan@example.com",
        buyer_first: "Buyer",
        buyer_last: "Person",
        buyer_email: "buyer@example.com",
        allowed_checkins: 1,
        used_checkins: 0,
        remaining_checkins: 1,
        checked_in?: false,
        payment_status: "completed",
        payment_date_raw: "2026-05-01",
        custom_fields: %{},
        raw_source_hash: "hash-#{System.unique_integer([:positive])}",
        last_seen_at: ~U[2026-05-19 10:00:00Z]
      }
      |> Map.merge(overrides)

    {:ok, snapshot} = TickeraAttendeeSnapshots.upsert_from_tickera(attrs, internal?: true)
    snapshot
  end

  defp findings_for_run!(run) do
    {:ok, findings} = TickeraReconciliationFindings.list_for_run(run.id, internal?: true)
    findings
  end

  defp finding(findings, type) do
    Enum.find(findings, &(&1.finding_type == type)) || flunk("missing finding #{type}")
  end

  defp fake_oban_insert do
    fn changeset -> {:ok, %{id: Ecto.UUID.generate(), changeset: changeset}} end
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
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

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp restore_test_raise!(nil),
    do: Application.delete_env(:event_sales, :tickera_reconciliation_test_raise)

  defp restore_test_raise!(value),
    do: Application.put_env(:event_sales, :tickera_reconciliation_test_raise, value)
end
