defmodule EventSales.Catalog.VariationMappingResolverTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Catalog.VariationMappingResolver
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers}

  setup do
    admin = create_user!("variation-resolver-admin@example.com")
    staff = create_user!("variation-resolver-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Resolution Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Resolved Ticket"})
    {run, hash} = create_manual_resolution_run!(source, 104_324, 501)

    {:ok,
     admin: admin,
     staff: staff,
     source: source,
     event: event,
     ticket: ticket,
     run: run,
     hash: hash}
  end

  test "admin prepares one exact ready run and preserves its review evidence", %{
    admin: admin,
    run: run,
    hash: hash
  } do
    snapshot = run.plan_snapshot

    assert {:ok, revoked} = VariationMappingResolver.prepare(run.id, hash, actor: admin)
    assert revoked.status == :cancelled
    assert revoked.cancellation_reason_code == :mapping_resolution_started
    assert revoked.cancellation_reason_details == "Manual variation mapping resolution started"
    assert revoked.plan_snapshot == snapshot
    assert revoked.dry_run_hash == hash

    assert {:error, :already_cancelled} =
             VariationMappingResolver.prepare(run.id, hash, actor: admin)
  end

  test "non-admin cannot prepare or resolve", %{
    staff: staff,
    run: run,
    hash: hash,
    event: event,
    ticket: ticket
  } do
    assert {:error, :forbidden} = VariationMappingResolver.prepare(run.id, hash, actor: staff)

    assert {:error, :forbidden} =
             VariationMappingResolver.resolve(
               run.id,
               hash,
               104_324,
               501,
               resolution_params(event, ticket),
               actor: staff
             )

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :dry_run_ready
    assert Ash.count!(ProductMapping, domain: Catalog) == 0
  end

  test "admin resolve rejects non-map params without mutation", %{
    admin: admin,
    run: run,
    hash: hash
  } do
    assert {:error, :invalid_params} =
             VariationMappingResolver.resolve(
               run.id,
               hash,
               104_324,
               501,
               :not_a_map,
               actor: admin
             )

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :dry_run_ready
    assert Ash.count!(ProductMapping, domain: Catalog) == 0
    refute_enqueued(worker: EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker)
  end

  test "resolution requires prepared exact run hash and identity", %{
    admin: admin,
    run: run,
    hash: hash,
    event: event,
    ticket: ticket
  } do
    params = resolution_params(event, ticket)

    assert {:error, :run_not_prepared} =
             VariationMappingResolver.resolve(run.id, hash, 104_324, 501, params, actor: admin)

    assert {:ok, _revoked} = VariationMappingResolver.prepare(run.id, hash, actor: admin)

    assert {:error, :stale_preview} =
             VariationMappingResolver.resolve(
               run.id,
               "wrong-hash",
               104_324,
               501,
               params,
               actor: admin
             )

    assert {:error, :variation_not_reviewed} =
             VariationMappingResolver.resolve(run.id, hash, 104_324, 999, params, actor: admin)

    assert {:error, :invalid_woo_variation_id} =
             VariationMappingResolver.resolve(run.id, hash, 104_324, nil, params, actor: admin)
  end

  test "prepared resolution delegates exact creation and audits safe provenance", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket,
    run: run,
    hash: hash
  } do
    assert {:ok, _revoked} = VariationMappingResolver.prepare(run.id, hash, actor: admin)

    assert {:ok, %{mapping: mapping}} =
             VariationMappingResolver.resolve(
               run.id,
               hash,
               104_324,
               501,
               resolution_params(event, ticket),
               actor: admin
             )

    assert mapping.source_system_id == source.id
    assert mapping.woo_product_id == 104_324
    assert mapping.woo_variation_id == 501

    assert [audit] =
             AuditLog
             |> Ash.Query.filter(event_type == :manual_mapping_created)
             |> Ash.read!(domain: Audit)

    assert audit.metadata["catalog_sync_run_id"] == run.id
    assert audit.metadata["dry_run_hash"] == hash
    assert audit.metadata["tickera_event_id"] == 109_120
    assert audit.metadata["woo_product_id"] == 104_324
    assert audit.metadata["woo_variation_id"] == 501
    assert audit.metadata["resolution_source"] == "variation_mapping_review"
    refute Map.has_key?(audit.metadata, "payload")
    refute Map.has_key?(audit.metadata, "secret")

    refute_enqueued(worker: EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker)
  end

  defp create_manual_resolution_run!(source, product_id, variation_id) do
    snapshot = manual_snapshot(source.id, product_id, variation_id)
    {:ok, _bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{dry_run_hash: hash, summary: %{}, plan_snapshot: snapshot}
      )

    {run, hash}
  end

  defp manual_snapshot(source_system_id, product_id, variation_id) do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_system_id,
      "origin" => "human_admin",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [
        %{
          "action" => "create",
          "event_ref" => "tickera_event:109120",
          "ticket_type_ref" => "woo_variation:#{variation_id}",
          "source_system_id" => source_system_id,
          "woo_product_id" => product_id,
          "woo_variation_id" => variation_id,
          "original_label" => "Reviewed variation",
          "current_label" => "Reviewed variation",
          "active" => true
        }
      ],
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
        "unresolved_destination_count" => 1,
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
        "product_keys" => [
          %{"woo_product_id" => product_id, "woo_variation_id" => variation_id}
        ]
      }
    }
  end

  defp resolution_params(event, ticket) do
    %{
      "event_id" => event.id,
      "ticket_type_mode" => "existing",
      "ticket_type_id" => ticket.id,
      "ticket_type_name" => "",
      "source_status" => "manual",
      "reason" => "Reviewed exact variation exception"
    }
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Variation Resolver User",
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
