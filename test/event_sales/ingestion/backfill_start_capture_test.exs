defmodule EventSales.Ingestion.BackfillStartCaptureTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Ingestion
  alias EventSales.Ingestion.BackfillStartCapture
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @source_created_at ~U[2026-05-01 08:00:00Z]
  @source_updated_at ~U[2026-06-01 10:00:00Z]

  test "exact trusted event-scoped run captures source creation time" do
    %{event: event, run: run} = ready_fixture()

    assert {:ok, %Event{} = captured} = BackfillStartCapture.capture(event.id, run.id)
    assert DateTime.compare(captured.source_created_at, @source_created_at) == :eq

    assert DateTime.compare(
             Ash.get!(Event, event.id, domain: Catalog).source_created_at,
             @source_created_at
           ) == :eq
  end

  test "captured value equals source post_date_gmt evidence" do
    %{event: event, run: run} = ready_fixture()

    assert {:ok, captured} = BackfillStartCapture.capture(event.id, run.id)
    assert DateTime.compare(captured.source_created_at, ~U[2026-05-01 08:00:00Z]) == :eq
  end

  test "repeated capture with the same timestamp is idempotent" do
    %{event: event, run: run} = ready_fixture()

    assert {:ok, first} = BackfillStartCapture.capture(event.id, run.id)
    assert {:ok, second} = BackfillStartCapture.capture(event.id, run.id)
    assert first.source_created_at == second.source_created_at
  end

  test "missing source creation evidence rejects" do
    %{event: event, run: run} = ready_fixture(source_created_at: nil)

    assert {:error, :missing_source_created_at} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "malformed source creation evidence rejects" do
    %{event: event, run: run} = ready_fixture(source_created_at: "not-a-date", hash: "forged")

    assert {:error, :snapshot_hash_mismatch} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "snapshot hash mismatch rejects" do
    %{event: event, run: run} = ready_fixture(hash: String.duplicate("0", 64))

    assert {:error, :snapshot_hash_mismatch} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "foreign SourceSystem run rejects" do
    %{event: event} = event_fixture()
    snapshot = snapshot_for(event, @source_created_at)
    foreign_source = SalesHelpers.create_source_system!()
    run = ready_run!(foreign_source, event, snapshot)

    assert {:error, :run_source_mismatch} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "foreign Event scope rejects" do
    %{source: source, event: event} = event_fixture()
    snapshot = snapshot_for(event, @source_created_at)
    run = ready_run!(source, event, snapshot, scope_event_id: event.external_event_id + 1)

    assert {:error, :run_scope_mismatch} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "non-event scope rejects" do
    %{source: source, event: event} = event_fixture()
    snapshot = snapshot_for(event, @source_created_at)
    run = ready_run!(source, event, snapshot, scope: %{"kind" => "manual_rows"})

    assert {:error, :run_scope_mismatch} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "run not dry_run_ready rejects" do
    %{source: source, event: event} = event_fixture()
    snapshot = snapshot_for(event, @source_created_at)
    run = queued_run!(source, event, snapshot)

    assert {:error, :run_not_ready} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "Event not backfill_pending rejects" do
    %{event: event, run: run} = ready_fixture(event_state: :unverified)

    assert {:error, :event_not_backfill_pending} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "existing different source creation time rejects" do
    %{event: event, run: run} = ready_fixture()

    assert {:ok, event} =
             Ash.update(
               event,
               %{source_created_at: ~U[2026-04-30 08:00:00Z]},
               action: :capture_source_created_at,
               domain: Catalog
             )

    assert {:error, :source_created_at_conflict} =
             BackfillStartCapture.capture(event.id, run.id)

    assert DateTime.compare(reload_event!(event).source_created_at, ~U[2026-04-30 08:00:00Z]) ==
             :eq
  end

  test "failure leaves an existing timestamp unchanged" do
    %{event: event, run: run} = ready_fixture(source_created_at: nil)

    assert {:ok, event} =
             Ash.update(
               event,
               %{source_created_at: ~U[2026-04-30 08:00:00Z]},
               action: :capture_source_created_at,
               domain: Catalog
             )

    assert {:error, :missing_source_created_at} = BackfillStartCapture.capture(event.id, run.id)

    assert DateTime.compare(reload_event!(event).source_created_at, ~U[2026-04-30 08:00:00Z]) ==
             :eq
  end

  test "capture leaves onboarding state backfill_pending" do
    %{event: event, run: run} = ready_fixture()

    assert {:ok, captured} = BackfillStartCapture.capture(event.id, run.id)
    assert captured.analytics_onboarding_state == :backfill_pending
  end

  test "capture does not mutate ProductMapping or TicketType" do
    %{source: source, event: event, run: run} = ready_fixture()
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Existing Ticket"})

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 70_101,
          woo_variation_id: nil,
          original_label: "Existing Ticket",
          current_label: "Existing Ticket",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    assert %{analytics_onboarding_state: :unverified} = reload_event!(event)

    event =
      Ash.update!(reload_event!(event), %{}, action: :mark_backfill_pending, domain: Catalog)

    assert {:ok, _captured} = BackfillStartCapture.capture(event.id, run.id)
    assert Ash.get!(TicketType, ticket.id, domain: Catalog).id == ticket.id
    assert Ash.get!(ProductMapping, mapping.id, domain: Catalog).id == mapping.id
  end

  test "capture creates no historical SyncRun" do
    %{event: event, run: run} = ready_fixture()
    before = Ash.count!(TickeraCatalogSyncRun, domain: Ingestion)

    assert {:ok, _captured} = BackfillStartCapture.capture(event.id, run.id)
    assert Ash.count!(TickeraCatalogSyncRun, domain: Ingestion) == before
  end

  test "capture writes no Order or OrderItem and enqueues no worker" do
    %{event: event, run: run} = ready_fixture()
    before_orders = Repo.aggregate(from(order in "sales_orders"), :count, :id)
    before_items = Repo.aggregate(from(item in "sales_order_items"), :count, :id)

    assert {:ok, _captured} = BackfillStartCapture.capture(event.id, run.id)
    assert Repo.aggregate(from(order in "sales_orders"), :count, :id) == before_orders
    assert Repo.aggregate(from(item in "sales_order_items"), :count, :id) == before_items
    assert all_enqueued() == []
  end

  test "foreign event evidence rejects" do
    %{source: source, event: event} = event_fixture()

    foreign_event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 70_102,
        external_event_kind: :tickera_event
      })

    snapshot = snapshot_for(foreign_event, @source_created_at)
    run = ready_run!(source, event, snapshot)

    assert {:error, :foreign_event} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  test "conflicting source creation evidence rejects" do
    %{source: source, event: event} = event_fixture()
    first = event_action(event, @source_created_at)
    second = event_action(event, ~U[2026-05-02 08:00:00Z])
    snapshot = snapshot_for(event, [first, second])
    run = ready_run!(source, event, snapshot)

    assert {:error, :source_created_at_conflict} = BackfillStartCapture.capture(event.id, run.id)
    assert is_nil(reload_event!(event).source_created_at)
  end

  defp ready_fixture(opts \\ []) do
    %{source: source, event: event} = event_fixture(opts)
    snapshot = snapshot_for(event, Keyword.get(opts, :source_created_at, @source_created_at))
    run = ready_run!(source, event, snapshot, hash: Keyword.get(opts, :hash))
    %{source: source, event: event, run: run, snapshot: snapshot}
  end

  defp event_fixture(opts \\ []) do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: Keyword.get(opts, :external_event_id, 70_100),
        external_event_kind: :tickera_event
      })

    event =
      case Keyword.get(opts, :event_state, :backfill_pending) do
        :backfill_pending ->
          Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

        :unverified ->
          event
      end

    %{source: source, event: event}
  end

  defp ready_run!(source, event, snapshot, opts \\ []) do
    hash =
      case Keyword.get(opts, :hash) do
        nil ->
          {:ok, _bytes, canonical_hash} = SnapshotCanonicalizer.canonicalize(snapshot)
          canonical_hash

        explicit_hash ->
          explicit_hash
      end

    scope =
      Keyword.get(opts, :scope, %{
        "kind" => "wordpress_feed",
        "event_id" => event.external_event_id
      })

    scope = Map.put(scope, "event_id", Keyword.get(opts, :scope_event_id, scope["event_id"]))

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: scope, origin: :human_admin},
        action: :create_dry_run,
        domain: Ingestion
      )

    run =
      Ash.update!(
        run,
        %{owner_attempt: 1, owner_max_attempts: 1},
        action: :mark_discovering,
        domain: Ingestion
      )

    Ash.update!(
      run,
      %{dry_run_hash: hash, summary: %{}, plan_snapshot: snapshot},
      action: :mark_dry_run_ready,
      domain: Ingestion
    )
  end

  defp queued_run!(source, event, _snapshot) do
    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source.id,
        scope: %{"kind" => "wordpress_feed", "event_id" => event.external_event_id},
        origin: :human_admin
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp snapshot_for(event, source_created_at_or_actions) do
    event_actions =
      if is_list(source_created_at_or_actions) do
        source_created_at_or_actions
      else
        [event_action(event, source_created_at_or_actions)]
      end

    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => event.source_system_id,
      "origin" => "human_admin",
      "event_actions" => event_actions,
      "ticket_type_actions" => [],
      "product_mapping_actions" => [],
      "findings" => [],
      "source_risks" => [],
      "historical_impact" => %{
        "totals" => %{
          "affected_pending_lines" => 0,
          "affected_quantity" => 0,
          "eligible_lines" => 0,
          "eligible_quantity" => 0,
          "deferred_lines" => 0,
          "deferred_quantity" => 0,
          "conflicting_lines" => 0,
          "conflicting_quantity" => 0,
          "already_mapped_lines" => 0,
          "already_mapped_quantity" => 0
        },
        "warning_count" => 0,
        "unresolved_destination_count" => 0,
        "unknown_classification_count" => 0,
        "destinations" => []
      },
      "identity_membership_proof" => %{
        "events" => [],
        "ticket_types" => [],
        "product_mappings" => []
      },
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" => []
      }
    }
  end

  defp event_action(event, source_created_at) do
    %{
      "action" => "update_metadata",
      "ref" => "tickera_event:#{event.external_event_id}",
      "event_id" => event.id,
      "source_status" => "publish",
      "source_created_at" => serialize_datetime(source_created_at),
      "source_updated_at" => DateTime.to_iso8601(@source_updated_at),
      "starts_at" => nil,
      "ends_at" => nil,
      "venue_name" => nil,
      "booking_fee_type" => nil,
      "booking_fee_value" => nil
    }
  end

  defp serialize_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp serialize_datetime(value), do: value

  defp reload_event!(event), do: Ash.get!(Event, event.id, domain: Catalog)
end
