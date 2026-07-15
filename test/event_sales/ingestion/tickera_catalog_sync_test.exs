defmodule EventSales.Ingestion.TickeraCatalogSyncTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers, TickeraCatalogFixtures}

  setup do
    admin = create_user!("tickera-catalog-admin@example.com")
    staff = create_user!("tickera-catalog-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    source = SalesHelpers.create_source_system!()

    {:ok, admin: admin, staff: staff, source: source}
  end

  test "queue_dry_run authorizes admins and enqueues discover worker", %{
    admin: admin,
    staff: staff,
    source: source
  } do
    scope = manual_scope()

    assert {:error, :forbidden} =
             TickeraCatalogSync.queue_dry_run(%{source_system_id: source.id, scope: scope},
               actor: staff
             )

    assert {:ok, %{run: run, job: job}} =
             TickeraCatalogSync.queue_dry_run(%{source_system_id: source.id, scope: scope},
               actor: admin
             )

    assert run.status == :queued
    assert job.queue == "tickera_sync"

    assert_enqueued(
      worker: DiscoverTickeraCatalogWorker,
      queue: :tickera_sync,
      args: %{"run_id" => run.id}
    )
  end

  test "queue_dry_run commits one queued run and one real Oban job", %{
    admin: admin,
    source: source
  } do
    run_count = catalog_sync_run_count()
    job_count = discovery_job_count()

    assert {:ok, %{run: run, job: job}} =
             TickeraCatalogSync.queue_dry_run(
               %{source_system_id: source.id, scope: manual_scope()},
               actor: admin
             )

    assert catalog_sync_run_count() == run_count + 1
    assert discovery_job_count() == job_count + 1

    persisted_job = Repo.get!(Oban.Job, job.id)
    assert persisted_job.args == %{"run_id" => run.id}
    assert persisted_job.queue == "tickera_sync"
  end

  test "queue_dry_run rolls back the queued run when discovery enqueue fails", %{
    admin: admin,
    source: source
  } do
    run_count = catalog_sync_run_count()
    job_count = discovery_job_count()

    assert {:error, :enqueue_failed} =
             TickeraCatalogSync.queue_dry_run(
               %{source_system_id: source.id, scope: manual_scope()},
               actor: admin,
               oban_insert: fn _job -> {:error, :injected_enqueue_failure} end
             )

    assert catalog_sync_run_count() == run_count
    assert discovery_job_count() == job_count
  end

  test "active-run partial unique index has the required predicate and permits terminal history",
       %{
         admin: admin,
         source: source
       } do
    index = active_run_index_metadata()

    assert index.name == "ingestion_tickera_catalog_sync_runs_one_active_per_source_idx"
    assert index.unique
    assert index.valid
    assert index.columns == ["source_system_id"]

    for status <- ~w(queued discovering retry_scheduled dry_run_ready applying) do
      assert index.predicate =~ status
    end

    queued = CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)

    assert {:error, error} =
             Ash.create(
               TickeraCatalogSyncRun,
               %{source_system_id: source.id, scope: %{"kind" => "manual_rows"}},
               action: :create_dry_run,
               domain: Ingestion
             )

    assert inspect(error) =~ "ingestion_tickera_catalog_sync_runs_one_active_per_source_idx"

    queued
    |> CatalogSyncRunHelpers.mark_discovering!()
    |> CatalogSyncRunHelpers.mark_failed!(%{last_error: "catalog_sync_discovery_failed"})

    assert {:ok, %{run: run}} =
             TickeraCatalogSync.queue_dry_run(
               %{source_system_id: source.id, scope: manual_scope()},
               actor: admin
             )

    assert run.status == :queued
  end

  test "queue_dry_run remains source-scoped for different active sources", %{
    admin: admin,
    source: source
  } do
    other_source = SalesHelpers.create_source_system!(%{name: "Catalog Sync Independent Source"})

    assert {:ok, %{run: first}} =
             TickeraCatalogSync.queue_dry_run(
               %{source_system_id: source.id, scope: manual_scope()},
               actor: admin
             )

    assert {:ok, %{run: second}} =
             TickeraCatalogSync.queue_dry_run(
               %{source_system_id: other_source.id, scope: manual_scope()},
               actor: admin
             )

    assert first.source_system_id == source.id
    assert second.source_system_id == other_source.id
  end

  test "list_runs and get_run_preview are admin-only", %{
    admin: admin,
    staff: staff,
    source: source
  } do
    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{"kind" => "manual_rows"}},
        action: :create_dry_run,
        domain: Ingestion
      )

    assert {:error, :forbidden} = TickeraCatalogSync.list_runs(actor: staff)
    assert {:ok, [_run]} = TickeraCatalogSync.list_runs(actor: admin)
    assert {:error, :forbidden} = TickeraCatalogSync.get_run_preview(run.id, actor: staff)
    assert {:ok, %{run: loaded_run}} = TickeraCatalogSync.get_run_preview(run.id, actor: admin)
    assert loaded_run.id == run.id
  end

  test "queue_apply rejects blocking findings before enqueue", %{admin: admin, source: source} do
    run =
      create_dry_run!(source.id, %{
        "dry_run_hash" => "blocked-hash",
        "event_changes" => [],
        "ticket_type_changes" => [],
        "product_mapping_changes" => [],
        "findings" => [
          %{
            "severity" => "blocking",
            "code" => "ambiguous_variation_ticket_type_name",
            "message" =>
              "Published product variation could not produce a distinct TicketType name."
          }
        ],
        "touched_event_ids" => [],
        "touched_product_keys" => []
      })

    assert {:error, :blocking_findings} =
             TickeraCatalogSync.queue_apply(run.id, "blocked-hash", actor: admin)

    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  test "queue_apply rejects missing previews before enqueue", %{admin: admin, source: source} do
    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{
          dry_run_hash: "missing-preview-hash",
          summary: %{"finding_count" => 4},
          plan_snapshot: nil
        }
      )

    assert {:error, :missing_plan_snapshot} =
             TickeraCatalogSync.queue_apply(run.id, "missing-preview-hash", actor: admin)

    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  test "global admin revokes a ready dry-run and preserves its snapshot", %{
    admin: admin,
    source: source
  } do
    snapshot = %{
      "dry_run_hash" => "revoked-hash",
      "event_changes" => [%{"action" => "create", "external_event_id" => 109_120}],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [%{"severity" => "warning", "code" => "expected_warning"}],
      "touched_event_ids" => [],
      "touched_product_keys" => []
    }

    run = create_dry_run!(source.id, snapshot)

    finding =
      Ash.create!(
        TickeraCatalogSyncFinding,
        %{
          run_id: run.id,
          severity: :warning,
          code: :expected_warning,
          message: "Expected advisory finding"
        },
        action: :create,
        domain: Ingestion
      )

    EventSales.Catalog.TickeraCatalog.PubSub.subscribe(run.id)

    assert {:ok, revoked} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{
                 cancellation_reason_code: :source_changed,
                 cancellation_reason_details: "  Publication state changed.  "
               },
               actor: admin
             )

    assert revoked.status == :cancelled
    assert revoked.cancelled_by_user_id == admin.id
    assert %DateTime{} = revoked.cancelled_at
    assert revoked.cancellation_reason_code == :source_changed
    assert revoked.cancellation_reason_details == "Publication state changed."
    assert revoked.dry_run_hash == run.dry_run_hash
    assert revoked.summary == run.summary
    assert revoked.plan_snapshot == run.plan_snapshot
    assert Ash.get!(TickeraCatalogSyncFinding, finding.id, domain: Ingestion).run_id == run.id
    assert_receive {:catalog_sync_cancelled, %{run_id: run_id}}
    assert run_id == run.id
    refute_enqueued(worker: ApplyTickeraCatalogWorker)
  end

  test "revocation is admin-only and validates bounded reasons", %{
    admin: admin,
    staff: staff,
    source: source
  } do
    run = create_dry_run!(source.id, ready_snapshot("reason-hash"))

    assert {:error, :forbidden} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{cancellation_reason_code: :source_changed},
               actor: staff
             )

    assert {:error, :forbidden} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{cancellation_reason_code: :source_changed},
               actor: nil
             )

    assert {:error, :invalid_reason_code} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{cancellation_reason_code: "forged_reason"},
               actor: admin
             )

    assert {:error, :reason_details_required} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{cancellation_reason_code: :other, cancellation_reason_details: "  "},
               actor: admin
             )

    assert {:error, :reason_details_too_long} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{
                 cancellation_reason_code: :operator_error,
                 cancellation_reason_details: String.duplicate("x", 501)
               },
               actor: admin
             )

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :dry_run_ready
  end

  test "only ready runs can be revoked and repeated revocation preserves audit", %{
    admin: admin,
    source: source
  } do
    for {status, expected_error} <- [
          queued: :run_not_revokeable,
          discovering: :run_not_revokeable,
          applying: :run_already_claimed,
          applied: :run_already_claimed,
          failed: :run_not_revokeable
        ] do
      run = fixture_run_for_status!(status, SalesHelpers.create_source_system!())

      assert {:error, ^expected_error} =
               TickeraCatalogSync.revoke_ready_dry_run(
                 run.id,
                 %{cancellation_reason_code: :incorrect_scope},
                 actor: admin
               )
    end

    run = create_dry_run!(source.id, ready_snapshot("repeat-hash"))

    assert {:ok, first} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{cancellation_reason_code: :superseded},
               actor: admin
             )

    assert {:error, :already_cancelled} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{
                 cancellation_reason_code: :other,
                 cancellation_reason_details: "Replace the original audit"
               },
               actor: admin
             )

    reloaded = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert reloaded.cancelled_at == first.cancelled_at
    assert reloaded.cancelled_by_user_id == first.cancelled_by_user_id
    assert reloaded.cancellation_reason_code == :superseded
    assert reloaded.cancellation_reason_details == nil

    assert {:error, _constraint_error} =
             Ash.update(reloaded, %{}, action: :mark_applied, domain: Ingestion)

    terminal = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert terminal.status == :cancelled
    assert terminal.cancelled_at == first.cancelled_at
  end

  test "Apply claim and revocation are mutually exclusive conditional transitions", %{
    admin: admin,
    source: source
  } do
    revoke_winner = create_dry_run!(source.id, ready_snapshot("revoke-wins"))

    assert {:ok, revoked} =
             TickeraCatalogSync.revoke_ready_dry_run(
               revoke_winner.id,
               %{cancellation_reason_code: :source_changed},
               actor: admin
             )

    assert {:error, :run_not_ready} =
             TickeraCatalogSync.claim_for_apply(revoked.id, "revoke-wins")

    apply_winner = create_dry_run!(source.id, ready_snapshot("apply-wins"))

    assert {:ok, applying} =
             TickeraCatalogSync.claim_for_apply(apply_winner.id, "apply-wins")

    assert applying.status == :applying

    assert {:error, :run_already_claimed} =
             TickeraCatalogSync.revoke_ready_dry_run(
               apply_winner.id,
               %{cancellation_reason_code: :unexpected_changes},
               actor: admin
             )

    assert is_nil(applying.cancelled_at)
    assert is_nil(applying.cancelled_by_user_id)
    assert is_nil(applying.cancellation_reason_code)
  end

  test "Apply claim requires the exact durable dry-run hash", %{source: source} do
    run = create_dry_run!(source.id, ready_snapshot("durable-hash"))

    assert {:error, :stale_dry_run_hash} =
             TickeraCatalogSync.claim_for_apply(run.id, "forged-hash")

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :dry_run_ready
  end

  test "simultaneous Apply claim and revocation permit exactly one winner", %{
    admin: admin,
    source: source
  } do
    run = create_dry_run!(source.id, ready_snapshot("race-hash"))
    parent = self()

    claim_task =
      Task.async(fn ->
        receive do
          :go -> TickeraCatalogSync.claim_for_apply(run.id, "race-hash")
        end
      end)

    revoke_task =
      Task.async(fn ->
        receive do
          :go ->
            TickeraCatalogSync.revoke_ready_dry_run(
              run.id,
              %{cancellation_reason_code: :source_changed},
              actor: admin
            )
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(EventSales.Repo, parent, claim_task.pid)
    Ecto.Adapters.SQL.Sandbox.allow(EventSales.Repo, parent, revoke_task.pid)
    send(claim_task.pid, :go)
    send(revoke_task.pid, :go)

    results = [Task.await(claim_task), Task.await(revoke_task)]
    assert Enum.count(results, &match?({:ok, _run}, &1)) == 1

    reloaded = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert reloaded.status in [:applying, :cancelled]

    if reloaded.status == :cancelled do
      assert %DateTime{} = reloaded.cancelled_at
      assert reloaded.cancelled_by_user_id == admin.id

      assert {:error, :run_not_ready} =
               TickeraCatalogSync.claim_for_apply(run.id, "race-hash")
    else
      assert is_nil(reloaded.cancelled_at)

      assert {:error, :run_already_claimed} =
               TickeraCatalogSync.revoke_ready_dry_run(
                 run.id,
                 %{cancellation_reason_code: :source_changed},
                 actor: admin
               )
    end
  end

  defp manual_scope do
    %{
      "kind" => "manual_rows",
      "events" => [TickeraCatalogFixtures.zero_product_event()],
      "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
    }
  end

  defp catalog_sync_run_count do
    TickeraCatalogSyncRun
    |> Ash.Query.new()
    |> Ash.count!(domain: Ingestion)
  end

  defp discovery_job_count do
    Repo.aggregate(Oban.Job, :count, :id)
  end

  defp active_run_index_metadata do
    %{rows: [[name, unique, valid, predicate, columns]]} =
      Repo.query!("""
      SELECT indexrelid::regclass::text,
             indisunique,
             indisvalid,
             pg_get_expr(indpred, indrelid),
             ARRAY(
               SELECT attribute.attname
               FROM unnest(indkey) WITH ORDINALITY AS key(attnum, position)
               JOIN pg_attribute AS attribute
                 ON attribute.attrelid = indrelid
                AND attribute.attnum = key.attnum
               ORDER BY key.position
             )
      FROM pg_index
      WHERE indexrelid = 'ingestion_tickera_catalog_sync_runs_one_active_per_source_idx'::regclass
      """)

    %{name: name, unique: unique, valid: valid, predicate: predicate, columns: columns}
  end

  defp create_dry_run!(source_system_id, snapshot) do
    queued =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source_system_id,
          scope: %{"kind" => "wordpress_feed", "mode" => "full"}
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    discovering = Ash.update!(queued, %{}, action: :mark_discovering, domain: Ingestion)

    Ash.update!(
      discovering,
      %{
        dry_run_hash: snapshot["dry_run_hash"],
        summary: %{"finding_count" => length(snapshot["findings"])},
        plan_snapshot: snapshot
      },
      action: :mark_dry_run_ready,
      domain: Ingestion
    )
  end

  defp fixture_run_for_status!(:queued, source),
    do: CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)

  defp fixture_run_for_status!(:discovering, source),
    do: CatalogSyncRunHelpers.create_discovering_catalog_sync_run!(source.id)

  defp fixture_run_for_status!(:failed, source),
    do:
      CatalogSyncRunHelpers.create_failed_catalog_sync_run!(source.id, %{"kind" => "manual_rows"})

  defp fixture_run_for_status!(status, source) when status in [:applying, :applied] do
    ready =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "manual_rows"},
        %{
          dry_run_hash: "fixture-#{status}",
          summary: %{},
          plan_snapshot: %{}
        }
      )

    applying = CatalogSyncRunHelpers.claim_applying!(ready)
    if status == :applied, do: CatalogSyncRunHelpers.mark_applied!(applying), else: applying
  end

  defp ready_snapshot(hash) do
    %{
      "dry_run_hash" => hash,
      "event_changes" => [],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [],
      "touched_event_ids" => [],
      "touched_product_keys" => []
    }
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
