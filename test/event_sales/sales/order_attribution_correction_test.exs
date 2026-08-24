defmodule EventSales.Sales.OrderAttributionCorrectionTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.DashboardCache
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.OrderAttributionCorrection
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-04-01 00:00:00.000000Z]
  @sales_covered_through ~U[2026-06-01 00:00:00.000000Z]

  setup do
    admin = create_user!("order-correction-admin@example.com")
    staff = create_user!("order-correction-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    ctx = correction_context!(source)

    {:ok, Map.merge(ctx, %{admin: admin, staff: staff, source: source})}
  end

  test "preview requires global admin", %{staff: staff, source: source} do
    assert {:error, :forbidden} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: staff)
  end

  test "missing order returns order_not_found", %{admin: admin} do
    source = SalesHelpers.create_source_system!()

    assert {:error, :order_not_found} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  test "successful correction changes exactly one order item and writes audit", %{
    admin: admin,
    source: source,
    order: order,
    order_item: order_item,
    mp_event: mp_event,
    mp_ticket: mp_ticket,
    wr_event: wr_event,
    wr_ticket: wr_ticket,
    wr_mapping: wr_mapping
  } do
    assert {:ok, preview} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)

    assert preview.woo_order_id == 113_834
    assert preview.woo_product_id == 109_132
    assert preview.woo_variation_id == 109_167
    assert preview.quantity == 5
    assert preview.current_event_external_id == 108_658
    assert preview.target_event_external_id == 109_120
    assert preview.current_ticket_type_name == mp_ticket.name
    assert preview.target_ticket_type_name == wr_ticket.name
    assert preview.order_item_id == order_item.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(mp_event.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(wr_event.id)

    assert {:error, :confirmation_required} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "wrong",
               actor: admin
             )

    assert {:ok, result} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120",
               actor: admin
             )

    assert result.order_item.id == order_item.id
    assert result.order_item.event_id == wr_event.id
    assert result.order_item.ticket_type_id == wr_ticket.id
    assert result.order_item.source_tickera_event_id == 109_120
    assert result.order_item.attribution_status_reason == nil
    assert result.order_item.mapping_status == :mapped
    assert result.order_item.item_kind == :ticket
    assert result.order_item.quantity == 5

    reloaded_order = Ash.get!(Order, order.id, domain: Sales)
    assert reloaded_order.woo_order_id == 113_834

    assert_event_unchanged(mp_event)
    assert_ticket_type_unchanged(mp_ticket)
    assert_event_unchanged(wr_event)
    assert_ticket_type_unchanged(wr_ticket)
    assert Ash.get!(ProductMapping, wr_mapping.id, domain: Catalog).active

    assert [audit] =
             AuditLog
             |> Ash.Query.filter(event_type == :order_attribution_corrected)
             |> Ash.read!(domain: Audit)

    assert audit.subject_type == "order_item"
    assert audit.subject_id == order_item.id
    assert audit.metadata["woo_order_id"] == 113_834
    assert audit.metadata["woo_product_id"] == 109_132
    assert audit.metadata["woo_variation_id"] == 109_167
    assert audit.metadata["quantity"] == 5
    assert audit.metadata["from_event_external_id"] == 108_658
    assert audit.metadata["to_event_external_id"] == 109_120
    refute Map.has_key?(audit.metadata, "confirmation")
  end

  test "successful correction invalidates both exact current Event certificates", %{
    admin: admin,
    source: source,
    order_item: order_item,
    mp_event: mp_event,
    wr_event: wr_event
  } do
    current_run = certified_run!(mp_event)
    target_run = certified_run!(wr_event)
    DashboardCache.ensure_table!()
    DashboardCache.put_event_summary(mp_event.id, %{total_sold: 5})
    DashboardCache.put_event_summary(wr_event.id, %{total_sold: 0})

    assert {:ok, %{order_item: corrected, preview: preview}} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120",
               actor: admin
             )

    assert corrected.id == order_item.id
    assert corrected.event_id == wr_event.id
    assert preview.current_event_external_id == 108_658
    assert preview.target_event_external_id == 109_120

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(mp_event.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(wr_event.id)

    assert Ash.get!(SyncRun, current_run.id, domain: Ingestion).order_coverage_status ==
             :incomplete

    assert Ash.get!(SyncRun, target_run.id, domain: Ingestion).order_coverage_status ==
             :incomplete

    assert :miss = DashboardCache.get_event_summary(mp_event.id)
    assert :miss = DashboardCache.get_event_summary(wr_event.id)
  end

  test "correction preserves certificates outside the Order sales scope", %{
    admin: admin,
    source: source,
    mp_event: mp_event,
    wr_event: wr_event
  } do
    current_run =
      certified_run!(mp_event,
        coverage_start: ~U[2026-06-01 00:00:00.000000Z],
        sales_covered_through: ~U[2026-07-01 00:00:00.000000Z]
      )

    target_run =
      certified_run!(wr_event,
        coverage_start: ~U[2026-06-01 00:00:00.000000Z],
        sales_covered_through: ~U[2026-07-01 00:00:00.000000Z]
      )

    assert {:ok, _result} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120",
               actor: admin
             )

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(mp_event.id)
    assert current.id == current_run.id
    assert {:ok, target} = HistoricalCoverageResolver.resolve_current(wr_event.id)
    assert target.id == target_run.id
  end

  test "rolls back correction, audit, and first invalidation when the second fails", %{
    admin: admin,
    source: source,
    order_item: order_item,
    mp_event: mp_event,
    wr_event: wr_event
  } do
    current_run = certified_run!(mp_event)
    target_run = certified_run!(wr_event)
    before_order_item = Ash.get!(OrderItem, order_item.id, domain: Sales)
    before_current = Ash.get!(SyncRun, current_run.id, domain: Ingestion)
    before_target = Ash.get!(SyncRun, target_run.id, domain: Ingestion)
    before_audit_count = audit_count()

    DashboardCache.ensure_table!()
    DashboardCache.put_event_summary(mp_event.id, %{total_sold: 5})
    DashboardCache.put_event_summary(wr_event.id, %{total_sold: 0})
    install_second_invalidation_failure_trigger!()

    assert {:error, :order_coverage_invalidation_failed} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120",
               actor: admin
             )

    assert Ash.get!(OrderItem, order_item.id, domain: Sales) == before_order_item
    assert Ash.get!(SyncRun, current_run.id, domain: Ingestion) == before_current
    assert Ash.get!(SyncRun, target_run.id, domain: Ingestion) == before_target
    assert audit_count() == before_audit_count
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(mp_event.id)
    assert current.id == current_run.id
    assert {:ok, target} = HistoricalCoverageResolver.resolve_current(wr_event.id)
    assert target.id == target_run.id
    assert {:ok, %{total_sold: 5}} = DashboardCache.get_event_summary(mp_event.id)
    assert {:ok, %{total_sold: 0}} = DashboardCache.get_event_summary(wr_event.id)
  end

  test "blocks when current event no longer matches confirmed tuple", %{
    admin: admin,
    source: source,
    order_item: order_item,
    wr_event: wr_event,
    wr_ticket: wr_ticket
  } do
    Ash.update!(
      order_item,
      %{event_id: wr_event.id, ticket_type_id: wr_ticket.id, source_tickera_event_id: 109_120},
      action: :correct_event_attribution,
      domain: Sales,
      actor: admin
    )

    assert {:error, :current_event_mismatch} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  test "blocks when target mapping is missing", %{
    admin: admin,
    source: source,
    wr_mapping: wr_mapping
  } do
    Ash.update!(wr_mapping, %{}, action: :deactivate, domain: Catalog, actor: admin)

    assert {:error, :target_mapping_missing} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  test "blocks multiple matching order items", %{
    admin: admin,
    source: source,
    order: order,
    mp_event: mp_event,
    mp_ticket: mp_ticket
  } do
    create_confirmed_order_item!(order, mp_event, mp_ticket)

    assert {:error, :multiple_order_items_found} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  defp correction_context!(source) do
    mp_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        external_event_id: 108_658,
        external_event_kind: :tickera_event
      })

    mp_ticket = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP General"})

    wr_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - WR",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    wr_ticket =
      SalesHelpers.create_ticket_type!(wr_event, %{
        name: "WR General",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 109_167,
        external_product_id: 109_132,
        external_variation_id: 109_167
      })

    wr_mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: wr_event.id,
          ticket_type_id: wr_ticket.id,
          woo_product_id: 109_132,
          woo_variation_id: 109_167,
          original_label: "WR General",
          current_label: "WR General",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    order =
      :order_completed
      |> SalesHelpers.normalized_order_attrs_from_fixture!(source)
      |> Map.merge(%{woo_order_id: 113_834, order_number: "113834"})
      |> then(&Ash.create!(Order, &1, action: :create_normalized, domain: Sales))

    order_item = create_confirmed_order_item!(order, mp_event, mp_ticket)

    %{
      order: order,
      order_item: order_item,
      mp_event: mp_event,
      mp_ticket: mp_ticket,
      wr_event: wr_event,
      wr_ticket: wr_ticket,
      wr_mapping: wr_mapping
    }
  end

  defp create_confirmed_order_item!(order, event, ticket) do
    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => 109_132,
      "variation_id" => 109_167,
      "name" => "WR General",
      "quantity" => 5,
      "subtotal" => "500.00",
      "total" => "500.00",
      "discount_total" => "0.00"
    }

    SalesHelpers.create_order_item_from_line!(order, line, %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      mapping_status: :mapped,
      item_kind: :ticket
    })
  end

  defp assert_event_unchanged(event) do
    reloaded = Ash.get!(Event, event.id, domain: Catalog)
    assert reloaded.name == event.name
    assert reloaded.external_event_id == event.external_event_id
    assert reloaded.external_event_kind == event.external_event_kind
    assert reloaded.updated_at == event.updated_at
  end

  defp assert_ticket_type_unchanged(ticket) do
    reloaded = Ash.get!(TicketType, ticket.id, domain: Catalog)
    assert reloaded.name == ticket.name
    assert reloaded.event_id == ticket.event_id
    assert reloaded.external_ticket_type_id == ticket.external_ticket_type_id
    assert reloaded.external_ticket_type_kind == ticket.external_ticket_type_kind
    assert reloaded.updated_at == ticket.updated_at
  end

  defp certified_run!(event, opts \\ []) do
    coverage_start = Keyword.get(opts, :coverage_start, @coverage_start)
    sales_covered_through = Keyword.get(opts, :sales_covered_through, @sales_covered_through)

    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(
      %{
        coverage_start: coverage_start,
        sales_covered_through: sales_covered_through,
        refunds_covered_through: sales_covered_through
      },
      action: :record_coverage_certification,
      domain: Ingestion
    )
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp audit_count do
    AuditLog
    |> Ash.Query.filter(event_type == :order_attribution_corrected)
    |> Ash.read!(domain: Audit)
    |> length()
  end

  defp install_second_invalidation_failure_trigger! do
    Repo.query!("""
    CREATE TEMP TABLE eventsales_test_order_invalidation_attempts (
      attempt integer NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION eventsales_test_fail_second_order_invalidation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      attempt_count integer;
    BEGIN
      IF NEW.coverage_invalidation_reason = 'historical_order_changed' THEN
        INSERT INTO eventsales_test_order_invalidation_attempts (attempt) VALUES (1);
        SELECT count(*) INTO attempt_count
        FROM eventsales_test_order_invalidation_attempts;

        IF attempt_count = 2 THEN
          RAISE EXCEPTION 'forced second order invalidation failure';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER eventsales_test_fail_second_order_invalidation
    BEFORE UPDATE ON ingestion_sync_runs
    FOR EACH ROW
    EXECUTE FUNCTION eventsales_test_fail_second_order_invalidation()
    """)
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
end
