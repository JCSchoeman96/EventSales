defmodule EventSales.Catalog.VariationMappingReviewTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Catalog.VariationMappingReview
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncFinding
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers}

  setup do
    admin = create_user!("variation-review-admin@example.com")
    create_global_role!(admin, :admin)
    source = SalesHelpers.create_source_system!()
    {:ok, admin: admin, source: source}
  end

  test "seven structural product warnings yield fourteen exact variation rows", %{
    admin: admin,
    source: source
  } do
    pairs =
      for product_offset <- 1..7,
          variation_offset <- 1..2 do
        product_id = 200_000 + product_offset
        variation_id = product_id * 10 + variation_offset
        event_id = 100_000 + product_offset
        {event_id, product_id, variation_id}
      end

    snapshot = planned_create_snapshot(source.id, pairs)
    {:ok, _bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{dry_run_hash: hash, summary: %{}, plan_snapshot: snapshot}
      )

    for product_offset <- 1..7 do
      product_id = 200_000 + product_offset

      Ash.create!(
        TickeraCatalogSyncFinding,
        %{
          run_id: run.id,
          severity: :warning,
          code: "variation_mapping_required",
          message: "Exact variation mappings are required.",
          tickera_event_id: 100_000 + product_offset,
          woo_product_id: product_id
        },
        action: :create,
        domain: Ingestion
      )
    end

    assert {:ok, review} = VariationMappingReview.list(run.id, hash, actor: admin)
    assert review.structural_warning_count == 7
    assert review.exact_variation_count == 14
    assert review.classification_summary == %{planned_create: 14}
    assert Enum.all?(review.rows, &(&1.classification == :planned_create))

    assert Enum.map(review.rows, &{&1.woo_product_id, &1.woo_variation_id}) ==
             pairs
             |> Enum.map(fn {_event_id, product_id, variation_id} ->
               {product_id, variation_id}
             end)
             |> Enum.sort()
  end

  test "classifies an active source-scoped exact mapping", %{admin: admin, source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Mapped Event",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Mapped Variation",
        external_ticket_type_id: 501,
        external_ticket_type_kind: :woo_variation,
        external_product_id: 104_324,
        external_variation_id: 501
      })

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: 104_324,
        woo_variation_id: 501,
        original_label: "Mapped Variation",
        current_label: "Mapped Variation",
        active: true
      },
      action: :create,
      domain: EventSales.Catalog
    )

    snapshot =
      source.id
      |> planned_create_snapshot([{109_120, 104_324, 501}])
      |> Map.put("event_actions", [])
      |> Map.put("ticket_type_actions", [])
      |> Map.put("product_mapping_actions", [])

    {run, hash} = create_ready_run!(source, snapshot)

    assert {:ok, %{rows: [row]}} = VariationMappingReview.list(run.id, hash, actor: admin)
    assert row.classification == :already_mapped_exact
    assert row.existing_event_external_id == 109_120
    assert row.existing_ticket_type_id == ticket.id
    refute row.manual_action_allowed
  end

  test "uses deterministic blocking, conflict, adoption, and manual precedence", %{
    admin: admin
  } do
    cases = [
      {"ambiguous_variation_ticket_type_name", :blocked_ambiguous_name},
      {"existing_mapping_conflict", :stale_mapping_conflict}
    ]

    for {code, expected} <- cases do
      source = SalesHelpers.create_source_system!()
      snapshot = planned_create_snapshot(source.id, [{109_120, 104_324, 501}])
      {run, hash} = create_ready_run!(source, snapshot)
      create_finding!(run, code, :blocking, 109_120, 104_324, 501)

      assert {:ok, %{rows: [%{classification: ^expected}]}} =
               VariationMappingReview.list(run.id, hash, actor: admin)
    end

    adopt_source = SalesHelpers.create_source_system!()

    adopt_snapshot =
      adopt_source.id
      |> planned_create_snapshot([{109_121, 104_325, 502}])
      |> Map.put("event_actions", [
        %{
          "action" => "adopt_existing",
          "event_id" => Ecto.UUID.generate(),
          "external_event_id" => 109_121,
          "external_event_kind" => "tickera_event",
          "source_status" => "publish",
          "source_updated_at" => nil,
          "starts_at" => nil,
          "ends_at" => nil,
          "venue_name" => nil,
          "booking_fee_type" => nil,
          "booking_fee_value" => nil
        }
      ])
      |> Map.put("ticket_type_actions", [
        %{
          "action" => "adopt_existing",
          "ticket_type_id" => Ecto.UUID.generate(),
          "event_id" => Ecto.UUID.generate(),
          "external_ticket_type_id" => 502,
          "external_ticket_type_kind" => "woo_variation",
          "external_product_id" => 104_325,
          "external_variation_id" => 502,
          "source_status" => "publish",
          "source_updated_at" => nil
        }
      ])
      |> Map.put("product_mapping_actions", [])

    {adopt_run, adopt_hash} = create_ready_run!(adopt_source, adopt_snapshot)

    assert {:ok, %{rows: [%{classification: :planned_adopt_existing}]}} =
             VariationMappingReview.list(adopt_run.id, adopt_hash, actor: admin)

    manual_source = SalesHelpers.create_source_system!()

    manual_snapshot =
      manual_source.id
      |> planned_create_snapshot([{109_122, 104_326, 503}])
      |> Map.put("event_actions", [])
      |> Map.put("ticket_type_actions", [])
      |> Map.put("product_mapping_actions", [])

    {manual_run, manual_hash} = create_ready_run!(manual_source, manual_snapshot)

    assert {:ok, %{rows: [%{classification: :manual_resolution_required}]}} =
             VariationMappingReview.list(manual_run.id, manual_hash, actor: admin)
  end

  test "rejects non-admin access and stale hashes", %{admin: admin, source: source} do
    snapshot = planned_create_snapshot(source.id, [{109_120, 104_324, 501}])
    {run, hash} = create_ready_run!(source, snapshot)

    assert {:error, :forbidden} = VariationMappingReview.list(run.id, hash, actor: nil)

    assert {:error, :stale_preview} =
             VariationMappingReview.list(run.id, "wrong-hash", actor: admin)
  end

  defp planned_create_snapshot(source_system_id, pairs) do
    event_ids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_system_id,
      "origin" => "human_admin",
      "event_actions" =>
        Enum.map(event_ids, fn event_id ->
          %{
            "action" => "create",
            "ref" => "tickera_event:#{event_id}",
            "source_system_id" => source_system_id,
            "name" => "Event #{event_id}",
            "slug" => "event-#{event_id}",
            "status" => "active",
            "external_event_id" => event_id,
            "external_event_kind" => "tickera_event",
            "source_status" => "publish",
            "source_updated_at" => nil,
            "starts_at" => nil,
            "ends_at" => nil,
            "venue_name" => nil,
            "booking_fee_type" => nil,
            "booking_fee_value" => nil
          }
        end),
      "ticket_type_actions" =>
        Enum.map(pairs, fn {event_id, product_id, variation_id} ->
          %{
            "action" => "create",
            "ref" => "woo_variation:#{variation_id}",
            "event_ref" => "tickera_event:#{event_id}",
            "name" => "Variation #{variation_id}",
            "active" => true,
            "external_ticket_type_id" => variation_id,
            "external_ticket_type_kind" => "woo_variation",
            "external_product_id" => product_id,
            "external_variation_id" => variation_id,
            "source_status" => "publish",
            "source_updated_at" => nil
          }
        end),
      "product_mapping_actions" =>
        Enum.map(pairs, fn {event_id, product_id, variation_id} ->
          %{
            "action" => "create",
            "event_ref" => "tickera_event:#{event_id}",
            "ticket_type_ref" => "woo_variation:#{variation_id}",
            "source_system_id" => source_system_id,
            "woo_product_id" => product_id,
            "woo_variation_id" => variation_id,
            "original_label" => "Variation #{variation_id}",
            "current_label" => "Variation #{variation_id}",
            "active" => true
          }
        end),
      "findings" => [],
      "source_risks" => [],
      "historical_impact" => empty_historical_impact(),
      "identity_membership_proof" => %{
        "events" => [],
        "ticket_types" => [],
        "product_mappings" => []
      },
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" =>
          Enum.map(pairs, fn {_event_id, product_id, variation_id} ->
            %{"woo_product_id" => product_id, "woo_variation_id" => variation_id}
          end)
      }
    }
  end

  defp empty_historical_impact do
    %{
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
    }
  end

  defp create_ready_run!(source, snapshot) do
    {:ok, _bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{dry_run_hash: hash, summary: %{}, plan_snapshot: snapshot}
      )

    {run, hash}
  end

  defp create_finding!(run, code, severity, event_id, product_id, variation_id) do
    Ash.create!(
      TickeraCatalogSyncFinding,
      %{
        run_id: run.id,
        severity: severity,
        code: code,
        message: code,
        tickera_event_id: event_id,
        woo_product_id: product_id,
        woo_variation_id: variation_id
      },
      action: :create,
      domain: Ingestion
    )
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Variation Review Admin",
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
