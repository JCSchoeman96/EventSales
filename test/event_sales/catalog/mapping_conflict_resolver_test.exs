defmodule EventSales.Catalog.MappingConflictResolverTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.MappingConflictResolver
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("mapping-conflict-admin@example.com")
    staff = create_user!("mapping-conflict-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()

    mp_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        slug: "lynette-beer-live-mp",
        external_event_id: 108_658,
        external_event_kind: :tickera_event
      })

    mp_ticket = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP General"})

    mapping =
      create_mapping!(source, mp_event, mp_ticket, %{
        woo_product_id: 109_132,
        woo_variation_id: 109_165,
        original_label: "MP General",
        current_label: "MP General"
      })

    {:ok,
     admin: admin,
     staff: staff,
     source: source,
     mp_event: mp_event,
     mp_ticket: mp_ticket,
     mapping: mapping}
  end

  test "lists safe conflict rows from an exact dry-run preview", %{
    admin: admin,
    source: source,
    mapping: mapping
  } do
    run = create_conflict_run!(source, "ready-hash")

    assert {:ok, [row]} =
             MappingConflictResolver.list_conflicts(run.id, "ready-hash", actor: admin)

    assert row.run_id == run.id
    assert row.dry_run_hash == "ready-hash"
    assert row.source_system_id == source.id
    assert row.woo_product_id == 109_132
    assert row.woo_variation_id == 109_165
    assert row.feed_tickera_event_id == 109_120
    assert row.mapped_event_name == "Lynette Beer LIVE - MP"
    assert row.mapped_event_external_event_id == 108_658
    assert row.mapped_ticket_type_name == "MP General"
    assert row.mapping_id == mapping.id
    assert row.order_item_count == 0
    assert row.resolution_status == :safe
    assert row.reason == :safe
    refute Map.has_key?(row, :mapping)
  end

  test "requires global admin for list and deactivate", %{staff: staff, source: source} do
    run = create_conflict_run!(source, "auth-hash")

    assert {:error, :forbidden} =
             MappingConflictResolver.list_conflicts(run.id, "auth-hash", actor: staff)

    assert {:error, :forbidden} =
             MappingConflictResolver.list_conflicts(run.id, "auth-hash", actor: nil)

    assert {:error, :forbidden} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               "auth-hash",
               109_132,
               109_165,
               actor: staff
             )
  end

  test "classifies stale preview integrity failures", %{admin: admin, source: source} do
    ready = create_conflict_run!(source, "ready-hash")
    failed_status = create_conflict_run!(source, "not-ready-hash", %{status: :failed})

    missing_snapshot =
      create_conflict_run!(source, "missing-snapshot-hash", %{plan_snapshot: nil})

    mismatched_snapshot =
      create_conflict_run!(source, "run-hash", %{
        plan_snapshot: conflict_snapshot("snapshot-hash")
      })

    assert {:error, :stale_preview} =
             MappingConflictResolver.list_conflicts("not-a-uuid", "ready-hash", actor: admin)

    assert {:error, :stale_preview} =
             MappingConflictResolver.list_conflicts(ready.id, nil, actor: admin)

    assert {:error, :stale_preview} =
             MappingConflictResolver.list_conflicts(ready.id, "wrong-hash", actor: admin)

    assert {:error, :stale_preview} =
             MappingConflictResolver.list_conflicts(failed_status.id, "not-ready-hash",
               actor: admin
             )

    assert {:error, :stale_preview} =
             MappingConflictResolver.list_conflicts(missing_snapshot.id, "missing-snapshot-hash",
               actor: admin
             )

    assert {:error, :stale_preview} =
             MappingConflictResolver.list_conflicts(mismatched_snapshot.id, "run-hash",
               actor: admin
             )
  end

  test "returns conflict_not_found for a valid preview without the requested conflict", %{
    admin: admin,
    source: source
  } do
    run = create_conflict_run!(source, "ready-hash")

    assert {:error, :conflict_not_found} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               "ready-hash",
               109_132,
               109_167,
               actor: admin
             )
  end

  test "blocks when the active mapping is missing or inactive", %{
    admin: admin,
    source: source,
    mapping: mapping
  } do
    run = create_conflict_run!(source, "ready-hash")
    Ash.update!(mapping, %{}, action: :deactivate, domain: Catalog, actor: admin)

    assert {:error, :mapping_not_active} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               "ready-hash",
               109_132,
               109_165,
               actor: admin
             )

    assert {:ok, [row]} =
             MappingConflictResolver.list_conflicts(run.id, "ready-hash", actor: admin)

    assert row.resolution_status == :blocked
    assert row.reason == :mapping_not_active
  end

  test "blocks manual review when mapping already points to the feed event", %{
    admin: admin,
    source: source,
    mapping: mapping
  } do
    wr_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - WR",
        slug: "lynette-beer-live-wr",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    wr_ticket = SalesHelpers.create_ticket_type!(wr_event, %{name: "WR General"})

    mapping
    |> Ash.Changeset.for_update(:remap, %{
      event_id: wr_event.id,
      ticket_type_id: wr_ticket.id,
      woo_product_id: 109_132,
      woo_variation_id: 109_165,
      original_label: "WR General",
      current_label: "WR General",
      active: true
    })
    |> Ash.update!(domain: Catalog, actor: admin)

    run = create_conflict_run!(source, "ready-hash")

    assert {:error, :manual_review_required} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               "ready-hash",
               109_132,
               109_165,
               actor: admin
             )
  end

  test "blocks when strict tuple ticket order history exists regardless of mapping status", %{
    admin: admin,
    source: source,
    mp_event: event,
    mp_ticket: ticket
  } do
    create_order_item!(source, event, ticket, %{
      woo_product_id: 109_132,
      woo_variation_id: 109_165,
      mapping_status: :pending_mapping_resolution,
      item_kind: :ticket
    })

    run = create_conflict_run!(source, "ready-hash")

    assert {:ok, [row]} =
             MappingConflictResolver.list_conflicts(run.id, "ready-hash", actor: admin)

    assert row.order_item_count == 1
    assert row.resolution_status == :blocked
    assert row.reason == :order_history_exists

    assert {:error, :order_history_exists} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               "ready-hash",
               109_132,
               109_165,
               actor: admin
             )
  end

  test "deactivate path uses a transaction-backed final guardrail recheck" do
    source = File.read!("lib/event_sales/catalog/mapping_conflict_resolver.ex")

    assert source =~ "deactivate_with_final_guardrails"
    assert source =~ "Repo.transaction"
    assert source =~ "Ash.Query.lock(query, :for_update)"
  end

  test "deactivates only the stale mapping through ProductMapping deactivate with PaperTrail", %{
    admin: admin,
    source: source,
    mp_event: event,
    mp_ticket: ticket,
    mapping: mapping
  } do
    run = create_conflict_run!(source, "ready-hash")
    event_before = Ash.get!(Event, event.id, domain: Catalog)
    ticket_before = Ash.get!(TicketType, ticket.id, domain: Catalog)
    order_items_before = Ash.count!(OrderItem, domain: Sales)

    assert {:ok, %{mapping: deactivated, conflict: conflict}} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               "ready-hash",
               109_132,
               109_165,
               actor: admin
             )

    refute deactivated.active
    assert conflict.reason == :safe
    assert conflict.mapping_id == mapping.id

    reloaded = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    refute reloaded.active

    assert Ash.get!(Event, event.id, domain: Catalog) == event_before
    assert Ash.get!(TicketType, ticket.id, domain: Catalog) == ticket_before
    assert Ash.count!(OrderItem, domain: Sales) == order_items_before

    versions =
      ProductMapping.Version
      |> Ash.Query.filter(version_source_id == ^mapping.id)
      |> Ash.read!(domain: Catalog)

    assert Enum.any?(versions, &(&1.version_action_name == :deactivate))
  end

  defp create_conflict_run!(source, hash, attrs \\ %{}) do
    defaults = %{
      source_system_id: source.id,
      scope: %{"kind" => "wordpress_feed", "mode" => "full"},
      status: :dry_run_ready,
      dry_run_hash: hash,
      summary: %{"finding_count" => 1},
      plan_snapshot: conflict_snapshot(hash)
    }

    Ash.create!(
      TickeraCatalogSyncRun,
      Map.merge(defaults, attrs),
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp conflict_snapshot(hash) do
    %{
      "dry_run_hash" => hash,
      "event_changes" => [],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [
        %{
          "severity" => "blocking",
          "code" => "existing_mapping_conflict",
          "message" => "Active ProductMapping points at a different catalog identity.",
          "tickera_event_id" => 109_120,
          "woo_product_id" => 109_132,
          "woo_variation_id" => 109_165
        }
      ],
      "touched_event_ids" => [],
      "touched_product_keys" => [[109_132, 109_165]]
    }
  end

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_order_item!(source, event, ticket, attrs) do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => attrs.woo_product_id,
      "variation_id" => attrs.woo_variation_id,
      "name" => "Historical ticket",
      "quantity" => 1,
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0.00"
    }

    SalesHelpers.create_order_item_from_line!(order, line, %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      mapping_status: attrs.mapping_status,
      item_kind: attrs.item_kind
    })
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
