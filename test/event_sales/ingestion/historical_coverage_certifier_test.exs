defmodule EventSales.Ingestion.HistoricalCoverageCertifierTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalCoverageCertifier
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.HistoricalCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers

  defmodule CoverageRepoFailure do
    def transaction(_fun), do: {:error, :coverage_database_unavailable}
  end

  @date_from ~U[2026-08-01 08:00:00.123456Z]
  @date_to ~U[2026-08-09 23:59:59.999999Z]
  @manifest_observed_at ~U[2026-08-13 11:00:00.000000Z]
  @catchup_observed_at ~U[2026-08-13 12:00:00.000000Z]
  @manifest_expires_at ~U[2026-08-13 13:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = historical_event!(source, @date_from)
    {run, cursor} = running_fixture!(source, event)

    {:ok, source: source, event: event, run: run, cursor: cursor}
  end

  test "valid terminal M/U evidence succeeds and returns B, C, and H", %{
    event: event,
    run: run,
    cursor: cursor
  } do
    assert {:ok, result} = HistoricalCoverageCertifier.evaluate(run, cursor)

    assert result.coverage_start == event.source_created_at
    assert result.coverage_start == @date_from
    assert result.sales_covered_through == run.date_to
    assert result.sales_covered_through == @date_to
    assert result.refunds_covered_through == @catchup_observed_at
  end

  test "H later than C is allowed", %{run: run, cursor: cursor} do
    assert {:ok, result} = HistoricalCoverageCertifier.evaluate(run, cursor)

    assert DateTime.compare(result.refunds_covered_through, result.sales_covered_through) == :gt
  end

  test "includes durable order facts at the inclusive sales boundary", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, _refund, _refund_line} =
      create_complete_facts!(source, event, created_at_source: @date_to)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:ok, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert result.coverage_evidence["orders"]["orders_durable"] == 1
  end

  test "certifies durable order, ticket, refund, and effective-time evidence", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, _refund, _refund_line} = create_complete_facts!(source, event)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:ok, result} = HistoricalCoverageCertifier.evaluate(run, cursor)

    assert result.coverage_evidence["result"] == "certified"

    assert result.coverage_evidence["orders"] == %{
             "manifest_members_seen" => 1,
             "orders_durable" => 1,
             "order_items_durable" => 1,
             "blocking_unresolved_count" => 0,
             "blocking_reasons" => %{}
           }

    assert result.coverage_evidence["refunds"] == %{
             "references_seen" => 1,
             "details_complete" => 1,
             "refund_lines_durable" => 1,
             "blocking_unresolved_count" => 0,
             "blocking_reasons" => %{}
           }
  end

  test "blocks when a matched manifest order has no durable event history", %{
    run: run,
    cursor: cursor
  } do
    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert result.coverage_evidence["result"] == "blocked"
    assert result.coverage_evidence["orders"]["blocking_reasons"]["order_history_incomplete"] == 1
  end

  test "blocks a mapped ticket line without its tax-inclusive primitive", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, item, _refund, _refund_line} = create_complete_facts!(source, event)
    clear_column!("sales_order_items", "line_total_tax", item.id)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "orders", "financial_primitive_incomplete")
  end

  test "blocks a recognised sale without an authoritative effective timestamp", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {order, _item, _refund, _refund_line} = create_complete_facts!(source, event)
    clear_column!("sales_orders", "paid_at", order.id)
    clear_column!("sales_orders", "completed_at", order.id)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "orders", "effective_time_incomplete")
  end

  test "blocks pending event attribution", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, item, _refund, _refund_line} = create_complete_facts!(source, event)
    Ash.update!(item, %{}, action: :remap, domain: Sales)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "orders", "attribution_incomplete")
  end

  test "blocks a source event identity conflict", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, item, _refund, _refund_line} = create_complete_facts!(source, event)
    other_event = historical_event!(source, @date_from)
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    Ash.update!(
      item,
      %{event_id: other_event.id, ticket_type_id: other_ticket.id},
      action: :correct_event_attribution,
      domain: Sales
    )

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "orders", "source_event_identity_conflict")
  end

  test "blocks an incomplete refund detail record", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, refund, _refund_line} = create_complete_facts!(source, event)

    Ash.update!(refund, %{detail_status: :reference_only},
      action: :sync_normalized,
      domain: Sales
    )

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_detail_incomplete")
  end

  test "blocks an active refund without an effective timestamp", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, refund, _refund_line} = create_complete_facts!(source, event)
    Ash.update!(refund, %{source_created_at: nil}, action: :sync_normalized, domain: Sales)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_effective_time_incomplete")
  end

  test "blocks a refund bound to the wrong parent order", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, refund, _refund_line} = create_complete_facts!(source, event)

    other_order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: 12_002,
          order_number: "12002",
          status: :completed,
          currency: "ZAR",
          completed_at: DateTime.add(@date_from, 5, :hour),
          created_at_source: DateTime.add(@date_from, 5, :hour),
          updated_at_source: DateTime.add(@date_from, 6, :hour),
          raw_total: Decimal.new("10"),
          raw_discount_total: Decimal.new("0"),
          raw_tax_total: Decimal.new("0")
        },
        action: :create_normalized,
        domain: Sales
      )

    Ash.update!(refund, %{order_id: other_order.id}, action: :sync_normalized, domain: Sales)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_parent_binding_incomplete")
  end

  test "blocks a refund line without an exact original-line binding", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, _refund, refund_line} = create_complete_facts!(source, event)

    Ash.update!(
      refund_line,
      %{order_item_id: nil},
      action: :sync_normalized,
      domain: Sales
    )

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_line_binding_incomplete")
  end

  test "blocks a complete refund with no durable refund lines", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, _refund, refund_line} = create_complete_facts!(source, event)

    Repo.query!("DELETE FROM sales_refund_lines WHERE id = $1", [Ecto.UUID.dump!(refund_line.id)])

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_line_binding_incomplete")
  end

  test "blocks a refund line whose source line ID disagrees with its bound line", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, item, _refund, refund_line} = create_complete_facts!(source, event)

    Repo.query!(
      "UPDATE sales_refund_lines SET woo_refunded_item_id = $2 WHERE id = $1",
      [Ecto.UUID.dump!(refund_line.id), item.woo_line_item_id + 1]
    )

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_line_binding_incomplete")
  end

  test "blocks a refund line with a validation conflict", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, _refund, refund_line} = create_complete_facts!(source, event)

    Ash.update!(
      refund_line,
      %{validation_reason: "refunded_quantity_exceeds_original"},
      action: :sync_normalized,
      domain: Sales
    )

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_line_validation_conflict")
  end

  test "blocks a refund with no durable financial primitive", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, refund, refund_line} = create_complete_facts!(source, event)
    clear_column!("sales_refunds", "header_amount", refund.id)
    clear_column!("sales_refund_lines", "refund_total_amount", refund_line.id)
    clear_column!("sales_refund_lines", "refund_total_tax", refund_line.id)

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:blocked, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert_reason(result, "refunds", "refund_financial_primitive_incomplete")
  end

  test "does not treat a voided refund's retained line diagnostics as active blockers", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    {_order, _item, refund, refund_line} = create_complete_facts!(source, event)

    Repo.query!(
      "UPDATE sales_refunds SET source_state = 'voided', voided_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(refund.id), @catchup_observed_at]
    )

    Ash.update!(
      refund_line,
      %{validation_reason: "retained_source_diagnostic"},
      action: :sync_normalized,
      domain: Sales
    )

    run =
      record_counts!(run, %{
        orders_seen_count: 1,
        orders_matched_count: 1,
        orders_upserted_count: 1
      })

    assert {:ok, result} = HistoricalCoverageCertifier.evaluate(run, cursor)
    assert result.coverage_evidence["refunds"]["blocking_reasons"] == %{}
  end

  test "rejects a non-historical run", %{source: source, event: event, cursor: cursor} do
    run =
      SyncRun
      |> Ash.Changeset.for_create(:queue_manual_scoped, %{
        source_system_id: source.id,
        event_id: event.id,
        date_from: @date_from,
        date_to: ~U[2026-08-02 08:00:00.000000Z],
        sync_mode: :shallow,
        requested_via: :manual
      })
      |> Ash.create!(
        domain: Ingestion,
        context: %{scoped_manual_sync_now: ~U[2026-08-15 12:00:00.000000Z]}
      )
      |> Ash.update!(%{}, action: :start, domain: Ingestion)

    manual_cursor = create_cursor!(run)

    assert {:error, :not_historical_backfill} =
             HistoricalCoverageCertifier.evaluate(run, manual_cursor)

    assert cursor.status == :active
  end

  test "rejects a non-running run", %{run: run, cursor: cursor} do
    paused =
      Ash.update!(
        run,
        %{paused_until: DateTime.add(@date_to, 1, :hour), pause_reason: :timeout},
        action: :pause,
        domain: Ingestion
      )

    assert {:error, :sync_run_not_running} =
             HistoricalCoverageCertifier.evaluate(paused, cursor)
  end

  test "rejects an already-certified run", %{run: run, cursor: cursor} do
    certified =
      Ash.update!(
        run,
        %{
          coverage_start: @date_from,
          sales_covered_through: @date_to,
          refunds_covered_through: @catchup_observed_at,
          coverage_evidence: HistoricalCoverageHelpers.certified_evidence()
        },
        action: :record_coverage_certification,
        domain: Ingestion
      )

    assert {:error, :coverage_already_certified} =
             HistoricalCoverageCertifier.evaluate(certified, cursor)
  end

  test "rejects a nonzero orders_failed_count", %{run: run, cursor: cursor} do
    run = Ash.update!(run, %{orders_failed_count: 1}, action: :record_counts, domain: Ingestion)

    assert {:error, :orders_failed_count_nonzero} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects a nonzero errors_count", %{run: run, cursor: cursor} do
    run = Ash.update!(run, %{errors_count: 1}, action: :record_counts, domain: Ingestion)

    assert {:error, :errors_count_nonzero} = HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects a missing Event", %{run: run, cursor: cursor} do
    missing_event_run = %{run | event_id: Ecto.UUID.generate()}

    assert {:error, :historical_event_missing} =
             HistoricalCoverageCertifier.evaluate(missing_event_run, cursor)
  end

  test "rejects an Event from another source", %{source: source, run: run, cursor: cursor} do
    foreign_source = SalesHelpers.create_source_system!()
    foreign_event = historical_event!(foreign_source, @date_from)
    wrong_event_run = %{run | event_id: foreign_event.id}

    assert {:error, :historical_event_source_mismatch} =
             HistoricalCoverageCertifier.evaluate(wrong_event_run, cursor)

    assert foreign_event.source_system_id != source.id
  end

  test "rejects an Event that is not BACKFILL_PENDING", %{event: event, run: run, cursor: cursor} do
    event = Ash.update!(event, %{}, action: :invalidate_onboarding, domain: Catalog)

    assert {:error, :historical_event_not_backfill_pending} =
             HistoricalCoverageCertifier.evaluate(run, cursor)

    assert event.analytics_onboarding_state == :unverified
  end

  test "rejects an Event with no source_created_at", %{source: source} do
    event = historical_event!(source, nil)
    {run, cursor} = running_fixture!(source, event)

    assert {:error, :missing_source_created_at} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects when Event.source_created_at differs from run.date_from", %{source: source} do
    event = historical_event!(source, DateTime.add(@date_from, 1, :second))
    {run, cursor} = running_fixture!(source, event)

    assert {:error, :historical_event_backfill_start_mismatch} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects a cursor belonging to another run", %{run: run, cursor: cursor} do
    wrong_cursor = %{cursor | sync_run_id: Ecto.UUID.generate()}

    assert {:error, :cursor_run_mismatch} =
             HistoricalCoverageCertifier.evaluate(run, wrong_cursor)
  end

  test "rejects a done cursor", %{run: run, cursor: cursor} do
    done =
      Ash.update!(cursor, %{metadata: cursor.metadata}, action: :mark_done, domain: Ingestion)

    assert {:error, :invalid_historical_cursor} =
             HistoricalCoverageCertifier.evaluate(run, done)
  end

  test "rejects a failed cursor", %{run: run, cursor: cursor} do
    failed =
      Ash.update!(cursor, %{metadata: cursor.metadata}, action: :mark_failed, domain: Ingestion)

    assert {:error, :invalid_historical_cursor} =
             HistoricalCoverageCertifier.evaluate(run, failed)
  end

  test "rejects cursor failure metadata", %{run: run, cursor: cursor} do
    failed_metadata = Map.put(cursor.metadata, "failure", "transport_failed")

    cursor =
      Ash.update!(
        cursor,
        %{metadata: failed_metadata},
        action: :record_catchup_evidence,
        domain: Ingestion
      )

    assert {:error, :cursor_failure_metadata} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects missing manifest evidence", %{run: run, cursor: cursor} do
    cursor = set_metadata!(cursor, Map.delete(cursor.metadata, "historical_manifest"))

    assert {:error, :manifest_evidence_missing} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects non-terminal manifest evidence", %{run: run, cursor: cursor} do
    {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata())

    metadata =
      cursor.metadata
      |> Map.merge(HistoricalManifestEvidence.in_progress_metadata(parent, "m-next.cursor"))

    cursor = set_metadata!(cursor, metadata)

    assert {:error, :manifest_not_terminal} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects corrupt manifest evidence", %{run: run, cursor: cursor} do
    metadata = put_in(cursor.metadata, ["historical_manifest", "manifest_hash"], "invalid")
    cursor = set_metadata!(cursor, metadata)

    assert {:error, :corrupt_manifest_evidence} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects missing catch-up evidence", %{run: run, cursor: cursor} do
    cursor = set_metadata!(cursor, Map.delete(cursor.metadata, "historical_catchup"))

    assert {:error, :catchup_evidence_missing} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects non-terminal catch-up evidence", %{run: run, cursor: cursor} do
    {:ok, child} = HistoricalCatchupEvidence.from_metadata(catchup_metadata())

    metadata =
      parent_metadata()
      |> Map.merge(HistoricalCatchupEvidence.in_progress_metadata(child, "u-next.cursor"))

    cursor = set_metadata!(cursor, metadata)

    assert {:error, :catchup_not_terminal} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects corrupt catch-up evidence", %{run: run, cursor: cursor} do
    metadata = put_in(cursor.metadata, ["historical_catchup", "manifest_hash"], "invalid")
    cursor = set_metadata!(cursor, metadata)

    assert {:error, :corrupt_catchup_evidence} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects a parent or binding continuity mismatch", %{run: run, cursor: cursor} do
    metadata =
      put_in(
        cursor.metadata,
        ["historical_catchup", "boundary_token"],
        "manifest-token"
      )

    cursor = set_metadata!(cursor, metadata)

    assert {:error, :catchup_parent_binding_mismatch} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects catch-up observation before manifest observation", %{run: run, cursor: cursor} do
    metadata =
      put_in(
        cursor.metadata,
        ["historical_catchup", "source_observed_at_gmt"],
        "2026-08-13T10:00:00.000000Z"
      )

    cursor = set_metadata!(cursor, metadata)

    assert {:error, :catchup_before_manifest} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "rejects reversed historical bounds", %{run: run, cursor: cursor} do
    run = %{run | date_to: DateTime.add(@date_from, -1, :second)}

    assert {:error, :invalid_historical_bounds} =
             HistoricalCoverageCertifier.evaluate(run, cursor)
  end

  test "evaluation performs no writes", %{event: event, run: run, cursor: cursor} do
    before = %{
      event: Ash.get!(Event, event.id, domain: Catalog),
      run: Ash.get!(SyncRun, run.id, domain: Ingestion),
      cursor: Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    }

    assert {:ok, _result} = HistoricalCoverageCertifier.evaluate(run, cursor)

    after_evaluation = %{
      event: Ash.get!(Event, event.id, domain: Catalog),
      run: Ash.get!(SyncRun, run.id, domain: Ingestion),
      cursor: Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    }

    assert after_evaluation == before
  end

  test "returns a retry outcome when local coverage reads fail", %{run: run, cursor: cursor} do
    assert {:retry, :coverage_evidence_read_failed} =
             HistoricalCoverageCertifier.evaluate(run, cursor, coverage_repo: CoverageRepoFailure)
  end

  defp historical_event!(source, source_created_at) do
    external_event_id = 800_000 + System.unique_integer([:positive])

    event =
      SalesHelpers.create_event!(source, %{
        name: "Coverage #{external_event_id}",
        slug: "coverage-#{System.unique_integer([:positive])}",
        external_event_id: external_event_id,
        external_event_kind: :tickera_event
      })

    event =
      case source_created_at do
        %DateTime{} = value ->
          Ash.update!(
            event,
            %{source_created_at: value},
            action: :capture_source_created_at,
            domain: Catalog,
            context: %{event_sales_backfill_start_capture_authority: {Event, :verified}}
          )

        nil ->
          event
      end

    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)
  end

  defp running_fixture!(source, event, date_from \\ @date_from, date_to \\ @date_to) do
    run =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{
        event_id: event.id,
        date_to: date_to
      })
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, date_from)
      |> Ash.create!(domain: Ingestion)
      |> Ash.update!(%{}, action: :start, domain: Ingestion)

    {run, create_cursor!(run)}
  end

  defp create_cursor!(run, metadata \\ nil) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      last_seen_order_id: nil,
      metadata: metadata || valid_metadata()
    })
    |> Ash.create!(domain: Ingestion)
  end

  defp set_metadata!(cursor, metadata) do
    Ash.update!(
      cursor,
      %{metadata: metadata},
      action: :record_catchup_evidence,
      domain: Ingestion
    )
  end

  defp valid_metadata do
    Map.merge(parent_metadata(), catchup_metadata())
  end

  defp parent_metadata do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => "manifest-token",
        "manifest_hash" => String.duplicate("a", 64),
        "manifest_expires_at_gmt" => DateTime.to_iso8601(@manifest_expires_at),
        "source_observed_at_gmt" => DateTime.to_iso8601(@manifest_observed_at),
        "state" => "manifest_terminal",
        "terminal_evidence" => "m-terminal-proof"
      }
    }
  end

  defp catchup_metadata(observed_at \\ @catchup_observed_at) do
    {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata())
    {:ok, child} = HistoricalCatchupEvidence.from_page(catchup_page(observed_at), parent)

    HistoricalCatchupEvidence.terminal_metadata(child, "u-terminal-proof")
  end

  defp catchup_page(observed_at) do
    %{
      "schema_version" => "2026-08-13.catchup.v1",
      "phase" => "catch_up",
      "boundary_token" => "catchup-token",
      "manifest_hash" => String.duplicate("b", 64),
      "manifest_expires_at_gmt" => DateTime.to_iso8601(@manifest_expires_at),
      "source_observed_at_gmt" => DateTime.to_iso8601(observed_at),
      "items" => [],
      "has_more" => false,
      "terminal_evidence" => "u-page-terminal-proof"
    }
  end

  defp record_counts!(run, attrs) do
    Ash.update!(run, attrs, action: :record_counts, domain: Ingestion)
  end

  defp create_complete_facts!(source, event, opts \\ []) do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Complete Ticket"})
    created_at_source = Keyword.get(opts, :created_at_source, DateTime.add(@date_from, 3, :hour))

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: 12_001,
          order_number: "12001",
          status: :completed,
          currency: "ZAR",
          completed_at: DateTime.add(@date_from, 2, :hour),
          paid_at: DateTime.add(@date_from, 1, :hour),
          created_at_source: created_at_source,
          updated_at_source: DateTime.add(@date_from, 4, :hour),
          raw_total: Decimal.new("207"),
          raw_discount_total: Decimal.new("20"),
          raw_tax_total: Decimal.new("27")
        },
        action: :create_normalized,
        domain: Sales
      )

    item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_line_item_id: 1,
          woo_product_id: 501,
          woo_variation_id: 601,
          name: "Complete Ticket",
          quantity: 2,
          line_subtotal: Decimal.new("200"),
          line_total: Decimal.new("180"),
          line_total_tax: Decimal.new("27"),
          discount_total: Decimal.new("20"),
          item_kind: :ticket,
          mapping_status: :mapped,
          source_tickera_event_id: event.external_event_id
        },
        action: :create_normalized,
        domain: Sales
      )

    refund =
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          order_id: order.id,
          woo_order_id: order.woo_order_id,
          woo_refund_id: 701,
          currency: "ZAR",
          source_state: :active,
          detail_status: :complete,
          summary_total_amount: Decimal.new("90"),
          header_amount: Decimal.new("90"),
          shipping_refund_amount: Decimal.new("0"),
          shipping_refund_tax: Decimal.new("0"),
          fee_refund_amount: Decimal.new("0"),
          fee_refund_tax: Decimal.new("0"),
          unallocated_header_amount: Decimal.new("0"),
          source_created_at: DateTime.add(@date_from, 2, :day)
        },
        action: :create_normalized,
        domain: Sales
      )

    refund_line =
      Ash.create!(
        RefundLine,
        %{
          refund_id: refund.id,
          order_item_id: item.id,
          woo_refund_line_item_id: 1,
          woo_refunded_item_id: item.woo_line_item_id,
          woo_product_id: item.woo_product_id,
          woo_variation_id: item.woo_variation_id,
          refunded_quantity: 1,
          refund_subtotal_amount: Decimal.new("100"),
          refund_total_amount: Decimal.new("90"),
          refund_total_tax: Decimal.new("13.5")
        },
        action: :create_normalized,
        domain: Sales
      )

    {order, item, refund, refund_line}
  end

  defp assert_reason(result, section, reason) do
    assert result.coverage_evidence[section]["blocking_reasons"][reason] > 0
  end

  defp clear_column!(table, column, id) do
    Repo.query!("UPDATE #{table} SET #{column} = NULL WHERE id = $1", [Ecto.UUID.dump!(id)])
  end
end
