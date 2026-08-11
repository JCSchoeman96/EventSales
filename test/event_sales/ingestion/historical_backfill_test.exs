defmodule EventSales.Ingestion.HistoricalBackfillTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.ManualSync
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @queue_now ~U[2026-08-10 12:00:00.000000Z]
  @backfill_start ~U[2026-08-01 08:00:00.123456Z]
  @cutoff ~U[2026-08-09 23:59:59.999999Z]

  setup do
    admin = create_admin!("historical-backfill-admin@example.com")
    source = SalesHelpers.create_source_system!()
    event = historical_event!(source)

    {:ok, admin: admin, source: source, event: event}
  end

  test "historical queue stores the derived scope and initial cursor", %{
    admin: admin,
    source: source,
    event: event
  } do
    assert {:ok, %{sync_run: run, sync_cursor: cursor}} = queue(event, admin)

    assert run.source_system_id == source.id
    assert run.event_id == event.id
    assert run.date_from == @backfill_start
    assert run.date_to == @cutoff
    assert run.sync_type == :historical_backfill
    assert run.sync_mode == :deep
    assert run.requested_via == :manual
    assert run.status == :queued

    assert cursor.sync_run_id == run.id
    assert cursor.page == 1
    assert cursor.modified_after == run.date_from
    assert cursor.modified_before == run.date_to
    assert cursor.last_seen_order_id == nil
    assert cursor.status == :active
    assert cursor.metadata == %{}

    assert Ash.count!(SyncCursor, domain: Ingestion) == 1

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(
               subject_id == ^run.id and event_type == :historical_backfill_requested
             )
             |> Ash.read(domain: Audit)

    assert audit.metadata["sync_type"] == "historical_backfill"
    assert audit.metadata["event_id"] == event.id
    assert audit.metadata["source_system_id"] == source.id
    assert audit.metadata["date_from"] == DateTime.to_iso8601(@backfill_start)
    assert audit.metadata["date_to"] == DateTime.to_iso8601(@cutoff)
    assert audit.metadata["requested_via"] == "manual"
    assert audit.metadata["result"] == "queued"
  end

  test "historical queue requires an explicit UTC cutoff", %{admin: admin, event: event} do
    assert {:error, :missing_backfill_cutoff} =
             ManualSync.queue_historical_backfill(event.id, nil, audit_attrs(admin),
               actor: admin,
               now: @queue_now
             )
  end

  test "missing Event.source_created_at fails closed", %{admin: admin, source: source} do
    event = historical_event!(source, source_created_at: nil)

    assert {:error, :missing_backfill_start} = queue(event, admin)
  end

  test "an Event outside backfill_pending is rejected", %{admin: admin, source: source} do
    event = historical_event!(source, onboarding_state: :unverified)

    assert {:error, :event_not_backfill_pending} = queue(event, admin)
  end

  test "an Event with invalid Tickera identity is rejected", %{admin: admin, source: source} do
    event = historical_event!(source, external_event_id: nil, external_event_kind: nil)

    assert {:error, :invalid_event_identity} = queue(event, admin)
  end

  test "a cutoff before the authoritative start is rejected", %{admin: admin, event: event} do
    assert {:error, :cutoff_before_backfill_start} =
             queue(event, admin, ~U[2026-07-31 23:59:59Z])
  end

  test "a future cutoff is rejected", %{admin: admin, event: event} do
    assert {:error, :future_backfill_cutoff} =
             queue(event, admin, ~U[2026-08-10 12:00:00.000001Z])
  end

  test "historical scope fields cannot be changed by lifecycle actions", %{
    admin: admin,
    event: event,
    source: source
  } do
    %{sync_run: run} = queue!(event, admin)

    for {field, value} <- [
          sync_type: :reconciliation,
          source_system_id: source.id,
          event_id: event.id,
          date_from: ~U[2026-07-31 00:00:00Z],
          date_to: @queue_now
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(run, %{field => value}, action: :record_counts, domain: Ingestion)
    end

    persisted = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert persisted.sync_type == :historical_backfill
    assert persisted.source_system_id == source.id
    assert persisted.event_id == event.id
    assert persisted.date_from == @backfill_start
    assert persisted.date_to == @cutoff
  end

  test "first active historical run succeeds and a second queued run rejects", %{
    admin: admin,
    event: event
  } do
    %{sync_run: first} = queue!(event, admin)

    assert first.status == :queued
    assert {:error, :active_historical_run_exists} = queue(event, admin)
    assert active_run_count(event) == 1
  end

  test "running and paused historical runs block another queue", %{admin: admin, event: event} do
    %{sync_run: running} = queue!(event, admin)
    running = Ash.update!(running, %{}, action: :start, domain: Ingestion)
    assert {:error, :active_historical_run_exists} = queue(event, admin)

    {:ok, paused} =
      Ash.update(
        running,
        %{paused_until: DateTime.add(@queue_now, 60, :second), pause_reason: :rate_limited},
        action: :pause,
        domain: Ingestion
      )

    assert paused.status == :paused
    assert {:error, :active_historical_run_exists} = queue(event, admin)
  end

  for terminal_status <- [:completed, :failed, :cancelled] do
    test "#{terminal_status} historical run permits a rerun", %{
      admin: admin,
      event: event
    } do
      %{sync_run: first} = queue!(event, admin)
      terminal = terminalize(first, unquote(terminal_status))
      assert terminal.status == unquote(terminal_status)

      assert {:ok, %{sync_run: second}} = queue(event, admin)
      refute second.id == first.id
      assert active_run_count(event) == 1
    end
  end

  test "same numeric external Event ID under different SourceSystems is isolated", %{
    admin: admin,
    event: event
  } do
    other_source = SalesHelpers.create_source_system!()
    other_event = historical_event!(other_source, external_event_id: event.external_event_id)

    assert {:ok, _first} = queue(event, admin)
    assert {:ok, _second} = queue(other_event, admin)
    assert active_run_count(event) == 1
    assert active_run_count(other_event) == 1
  end

  test "different Events under one SourceSystem may each have an active run", %{
    admin: admin,
    source: source,
    event: event
  } do
    other_event = historical_event!(source, external_event_id: event.external_event_id + 1)

    assert {:ok, _first} = queue(event, admin)
    assert {:ok, _second} = queue(other_event, admin)
    assert active_run_count(event) == 1
    assert active_run_count(other_event) == 1
  end

  test "concurrent queue attempts leave exactly one active historical run", %{
    admin: admin,
    event: event
  } do
    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> queue(event, admin) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :active_historical_run_exists}, &1)) == 1
    assert active_run_count(event) == 1
  end

  test "cursor creation failure rolls back the historical run", %{admin: admin, event: event} do
    assert {:error, :cursor_create_failed} =
             ManualSync.queue_historical_backfill(event.id, @cutoff, audit_attrs(admin),
               actor: admin,
               now: @queue_now,
               test_cursor_creator: fn _run -> {:error, :cursor_create_failed} end
             )

    assert Ash.count!(SyncRun, domain: Ingestion) == 0
    assert Ash.count!(SyncCursor, domain: Ingestion) == 0
  end

  test "replaying initial cursor creation does not create a duplicate cursor", %{
    admin: admin,
    event: event
  } do
    %{sync_run: run, sync_cursor: first_cursor} = queue!(event, admin)

    assert {:ok, second_cursor} =
             SyncCursor
             |> Ash.Changeset.for_create(:upsert_active, %{
               sync_run_id: run.id,
               page: 1,
               modified_after: run.date_from,
               modified_before: run.date_to,
               last_seen_order_id: nil,
               metadata: %{}
             })
             |> Ash.create(domain: Ingestion)

    assert second_cursor.id == first_cursor.id
    assert Ash.count!(SyncCursor, domain: Ingestion) == 1
  end

  test "historical queueing creates no orders, items, refunds, or Oban jobs", %{
    admin: admin,
    event: event
  } do
    orders_before = Repo.aggregate(from(order in "sales_orders"), :count, :id)
    items_before = Repo.aggregate(from(item in "sales_order_items"), :count, :id)

    assert {:ok, _result} = queue(event, admin)

    assert Repo.aggregate(from(order in "sales_orders"), :count, :id) == orders_before
    assert Repo.aggregate(from(item in "sales_order_items"), :count, :id) == items_before
    assert all_enqueued() == []
  end

  defp queue(event, admin, cutoff \\ @cutoff, opts \\ []) do
    ManualSync.queue_historical_backfill(
      event.id,
      cutoff,
      audit_attrs(admin),
      Keyword.merge([actor: admin, now: @queue_now], opts)
    )
  end

  defp queue!(event, admin, cutoff \\ @cutoff) do
    assert {:ok, result} = queue(event, admin, cutoff)
    result
  end

  defp active_run_count(event) do
    SyncRun
    |> Ash.Query.filter(event_id == ^event.id and source_system_id == ^event.source_system_id)
    |> Ash.read!(domain: Ingestion)
    |> Enum.count(fn run ->
      run.sync_type == :historical_backfill and run.status in [:queued, :running, :paused]
    end)
  end

  defp terminalize(run, :completed) do
    run
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp terminalize(run, :failed) do
    run
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(%{last_error: "test failure"}, action: :fail, domain: Ingestion)
  end

  defp terminalize(run, :cancelled), do: Ash.update!(run, %{}, action: :cancel, domain: Ingestion)

  defp historical_event!(source, opts \\ []) do
    external_event_id =
      Keyword.get(opts, :external_event_id, 70_500 + System.unique_integer([:positive]))

    external_event_kind = Keyword.get(opts, :external_event_kind, :tickera_event)
    source_created_at = Keyword.get(opts, :source_created_at, @backfill_start)
    onboarding_state = Keyword.get(opts, :onboarding_state, :backfill_pending)

    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical #{external_event_id}",
        slug: unique_slug("historical"),
        external_event_id: external_event_id,
        external_event_kind: external_event_kind
      })

    event =
      if onboarding_state == :backfill_pending do
        Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)
      else
        event
      end

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
  end

  defp audit_attrs(admin) do
    %{
      actor_type: :user,
      actor_user_id: admin.id,
      actor_role: :admin,
      source: :admin
    }
  end

  defp create_admin!(email) do
    user =
      Ash.create!(
        User,
        %{
          email: email,
          name: "Historical Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == :admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
