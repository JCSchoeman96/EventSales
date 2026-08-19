defmodule EventSales.Ingestion.HistoricalCoverageCertifierTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalCoverageCertifier
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.TestSupport.SalesHelpers

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
          refunds_covered_through: @catchup_observed_at
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
end
