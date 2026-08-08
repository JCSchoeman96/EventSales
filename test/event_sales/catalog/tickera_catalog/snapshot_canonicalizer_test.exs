defmodule EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizerTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer

  @keys ~w(
    snapshot_schema_version source_system_id origin event_actions
    ticket_type_actions product_mapping_actions findings source_risks
    historical_impact identity_membership_proof touched_identifiers
  )

  @v3_keys ~w(
    snapshot_schema_version source_system_id origin source event_actions
    ticket_type_actions product_mapping_actions findings
    canonical_source_risk_facts canonical_source_risk_findings
    historical_impact identity_membership_proof touched_identifiers
  )

  @v2_pinned_hash "76738311f87c33f46d558bdcf0ff352ba058ebce4b316641f9352a46acc478d2"

  test "pins the v2 canonical hash so Phase 5C cannot silently change live v2 bytes" do
    assert {:ok, _bytes, hash} = canonicalize(valid_snapshot())
    assert hash == @v2_pinned_hash
  end

  test "canonicalizes the exact eleven-key v2 snapshot independently of insertion order" do
    snapshot = valid_snapshot()
    reversed = snapshot |> Enum.reverse() |> Map.new()

    assert {:ok, bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)
    assert {:ok, ^bytes, ^hash} = SnapshotCanonicalizer.canonicalize(reversed)
    assert byte_size(hash) == 64
    assert Map.keys(snapshot) |> Enum.sort() == Enum.sort(@keys)
  end

  test "rejects unknown and missing top-level keys including dry_run_hash" do
    assert {:error, :invalid_snapshot_schema} =
             valid_snapshot()
             |> Map.put("dry_run_hash", String.duplicate("0", 64))
             |> canonicalize()

    assert {:error, :invalid_snapshot_schema} =
             valid_snapshot() |> Map.delete("findings") |> canonicalize()
  end

  test "rejects floats and normalizes decimals and datetimes deterministically" do
    assert {:error, :invalid_snapshot_value} =
             valid_snapshot()
             |> put_in(["historical_impact", "warning_count"], 0.0)
             |> canonicalize()

    snapshot =
      valid_snapshot()
      |> put_in(
        ["event_actions", Access.at(0), "booking_fee_value"],
        Decimal.new("-0.000")
      )
      |> put_in(
        ["event_actions", Access.at(0), "source_updated_at"],
        ~U[2026-07-22 10:00:00.123456Z]
      )

    assert {:ok, bytes, _hash} = canonicalize(snapshot)
    assert bytes =~ ~s("booking_fee_value":"0")
    assert bytes =~ ~s("source_updated_at":"2026-07-22T10:00:00.123456Z")
  end

  test "rejects unknown keys recursively in every nested object" do
    paths = [
      ["event_actions", Access.at(0)],
      ["ticket_type_actions", Access.at(0)],
      ["product_mapping_actions", Access.at(0)],
      ["findings", Access.at(0)],
      ["source_risks", Access.at(0)],
      ["historical_impact", "destinations", Access.at(0)],
      ["identity_membership_proof", "events", Access.at(0)],
      ["identity_membership_proof", "ticket_types", Access.at(0)],
      ["identity_membership_proof", "product_mappings", Access.at(0)],
      ["touched_identifiers", "product_keys", Access.at(0)]
    ]

    for path <- paths do
      invalid = update_in(valid_snapshot(), path, &Map.put(&1, "unexpected", "unsafe"))
      assert {:error, :invalid_snapshot_schema} = canonicalize(invalid)
    end
  end

  test "uses semantic collection keys so input permutations have identical bytes and hash" do
    snapshot = valid_snapshot()

    reversed =
      snapshot
      |> Map.update!("event_actions", &Enum.reverse/1)
      |> Map.update!("ticket_type_actions", &Enum.reverse/1)
      |> Map.update!("product_mapping_actions", &Enum.reverse/1)
      |> Map.update!("findings", &Enum.reverse/1)
      |> Map.update!("source_risks", &Enum.reverse/1)
      |> update_in(["historical_impact", "destinations"], &Enum.reverse/1)
      |> update_in(["identity_membership_proof", "events"], &Enum.reverse/1)
      |> update_in(["identity_membership_proof", "ticket_types"], &Enum.reverse/1)
      |> update_in(["identity_membership_proof", "product_mappings"], &Enum.reverse/1)
      |> update_in(["touched_identifiers", "product_keys"], &Enum.reverse/1)

    assert {:ok, bytes, hash} = canonicalize(snapshot)
    assert {:ok, ^bytes, ^hash} = canonicalize(reversed)
  end

  test "canonicalizes the exact thirteen-key v3 snapshot independently of insertion order" do
    snapshot = valid_v3_snapshot()

    assert Map.keys(snapshot) |> Enum.sort() == Enum.sort(@v3_keys)
    assert {:ok, bytes, hash} = canonicalize(snapshot)
    assert {:ok, ^bytes, ^hash} = canonicalize(snapshot |> Enum.reverse() |> Map.new())
    assert byte_size(hash) == 64
    assert bytes =~ ~s("snapshot_schema_version":"tickera_catalog_plan.v3")
  end

  test "v3 hashes are stable when facts, provenance, and findings arrive shuffled" do
    snapshot = valid_v3_snapshot()

    shuffled =
      snapshot
      |> Map.update!("canonical_source_risk_facts", fn facts ->
        facts
        |> Enum.reverse()
        |> Enum.map(&Map.update!(&1, "provenance", fn records -> Enum.reverse(records) end))
      end)
      |> Map.update!("canonical_source_risk_findings", &Enum.reverse/1)
      |> Map.update!("findings", &Enum.reverse/1)
      |> Map.update!("event_actions", &Enum.reverse/1)
      |> Map.update!("ticket_type_actions", &Enum.reverse/1)
      |> Map.update!("product_mapping_actions", &Enum.reverse/1)

    assert {:ok, bytes, hash} = canonicalize(snapshot)
    assert {:ok, ^bytes, ^hash} = canonicalize(shuffled)
  end

  test "v3 retains every multi-record provenance entry" do
    assert {:ok, bytes, _hash} = canonicalize(valid_v3_snapshot())

    assert bytes =~ ~s("raw_producer_code":"draft_product")
    assert bytes =~ ~s("raw_producer_code":"private_product")
  end

  test "v3 rejects unknown top-level keys and v2-only collections" do
    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot() |> Map.put("source_risks", []) |> canonicalize()

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot()
             |> Map.put("dry_run_hash", String.duplicate("0", 64))
             |> canonicalize()

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot() |> Map.delete("source") |> canonicalize()
  end

  test "v3 requires the locked native source envelope" do
    for {key, value} <- [
          {"schema_version", "2026-07-22.v2"},
          {"canonical_contract_version", "compat.v2_to_source_risk_v3.v1"},
          {"evidence_origin", "compatibility_derived"},
          {"producer_version", ""},
          {"producer_version", "2026-08-07.2"}
        ] do
      assert {:error, :invalid_snapshot_schema} =
               valid_v3_snapshot() |> put_in(["source", key], value) |> canonicalize()
    end
  end

  test "v3 requires exact producer_version 2026-08-07.1" do
    assert {:ok, _bytes, _hash} = canonicalize(valid_v3_snapshot())

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot()
             |> put_in(["source", "producer_version"], "2026-08-07.2")
             |> canonicalize()
  end

  test "v3 and v2 finding allowlists stay separate and closed" do
    assert {:error, :invalid_snapshot_schema} =
             valid_snapshot()
             |> put_in(["findings", Access.at(0), "code"], "source_risk.lifecycle_draft")
             |> canonicalize()

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot()
             |> put_in(["findings", Access.at(0), "code"], "missing_source_risk_data")
             |> canonicalize()

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot()
             |> put_in(["findings", Access.at(0), "code"], "source_risk.invented_code")
             |> canonicalize()
  end

  test "v3 rejects unknown nested keys, unknown vocabulary, and apply-eligible claims" do
    paths = [
      ["canonical_source_risk_facts", Access.at(0)],
      ["canonical_source_risk_facts", Access.at(0), "provenance", Access.at(0)],
      ["canonical_source_risk_findings", Access.at(0)],
      ["findings", Access.at(0)],
      ["findings", Access.at(0), "context"]
    ]

    for path <- paths do
      invalid = update_in(valid_v3_snapshot(), path, &Map.put(&1, "unexpected", "unsafe"))
      assert {:error, :invalid_snapshot_schema} = canonicalize(invalid)
    end

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot()
             |> put_in(["canonical_source_risk_facts", Access.at(0), "dimension"], "invented")
             |> canonicalize()

    assert {:error, :invalid_snapshot_schema} =
             valid_v3_snapshot()
             |> put_in(
               ["canonical_source_risk_findings", Access.at(0), "implies_apply_eligible"],
               true
             )
             |> canonicalize()
  end

  defp canonicalize(snapshot), do: SnapshotCanonicalizer.canonicalize(snapshot)

  defp valid_v3_snapshot do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v3",
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "origin" => "human_admin",
      "source" => %{
        "schema_version" => "2026-08-07.v3",
        "canonical_contract_version" => "source_risk.v3",
        "producer_version" => "2026-08-07.1",
        "source_system_id" => "wordpress_tickera:" <> String.duplicate("a", 64),
        "discovery_snapshot_id" => "snapshot-1",
        "source_snapshot_at" => "2026-08-07T09:00:00.000000Z",
        "evidence_origin" => "native"
      },
      "event_actions" => [event_create(2), event_create(1)],
      "ticket_type_actions" => [ticket_create(20), ticket_create(10)],
      "product_mapping_actions" => [mapping_create(20), mapping_create(10)],
      "findings" => [
        v3_finding("blocking", "source_risk.lifecycle_draft"),
        v3_finding("info", "existing_mapping_adopted")
      ],
      "canonical_source_risk_facts" => [fact(20), fact(10)],
      "canonical_source_risk_findings" => [
        v3_risk_finding("source_risk.lifecycle_draft", "explicit_risk"),
        v3_risk_finding("contract.evidence_conflict", "blocking_conflict")
      ],
      "historical_impact" => valid_snapshot()["historical_impact"],
      "identity_membership_proof" => valid_snapshot()["identity_membership_proof"],
      "touched_identifiers" => valid_snapshot()["touched_identifiers"]
    }
  end

  defp v3_finding(severity, code) do
    %{
      "severity" => severity,
      "code" => code,
      "target_type" => "run",
      "target_id" => nil,
      "context" => %{"disposition" => "explicit_risk", "dimension_local_only" => true}
    }
  end

  defp v3_risk_finding(qualified_finding_id, disposition) do
    %{
      "qualified_finding_id" => qualified_finding_id,
      "severity" => "blocking",
      "disposition" => disposition,
      "dimension_local_only" => true,
      "implies_apply_eligible" => false
    }
  end

  defp fact(id) do
    %{
      "run_id" => "snapshot-1",
      "dimension" => "lifecycle",
      "semantic_scope" => "parent_product",
      "target" => %{"woo_product_id" => id},
      "authority_slot" => "slot.lifecycle.wp_post_status",
      "authority" => "auth.wp_post_status",
      "state" => "present",
      "completeness" => "exhaustive",
      "origin" => "native",
      "value" => "draft",
      "provenance" => [
        %{
          "discovery_snapshot_id" => "snapshot-1",
          "producer_source_key" => "wp_posts.post_status",
          "raw_producer_code" => "private_product",
          "woo_product_id" => id
        },
        %{
          "discovery_snapshot_id" => "snapshot-1",
          "producer_source_key" => "wp_posts.post_status",
          "raw_producer_code" => "draft_product",
          "woo_product_id" => id
        }
      ]
    }
  end

  defp valid_snapshot do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "origin" => "targeted_catalog_change",
      "event_actions" => [
        event_create(2),
        event_create(1)
      ],
      "ticket_type_actions" => [
        ticket_create(20),
        ticket_create(10)
      ],
      "product_mapping_actions" => [
        mapping_create(20),
        mapping_create(10)
      ],
      "findings" => [
        finding("warning", 20),
        finding("info", 10)
      ],
      "source_risks" => [
        risk("product", 20),
        risk("event", 10)
      ],
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
        "destinations" => [
          destination(20),
          destination(10)
        ]
      },
      "identity_membership_proof" => %{
        "events" => [event_proof(2), event_proof(1)],
        "ticket_types" => [ticket_proof(20), ticket_proof(10)],
        "product_mappings" => [mapping_proof(20), mapping_proof(10)]
      },
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" => [
          %{"woo_product_id" => 20, "woo_variation_id" => nil},
          %{"woo_product_id" => 10, "woo_variation_id" => nil}
        ]
      }
    }
  end

  defp event_create(id) do
    %{
      "action" => "create",
      "ref" => "event:#{id}",
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "name" => "Event #{id}",
      "slug" => "event-#{id}",
      "status" => "active",
      "external_event_id" => id,
      "external_event_kind" => "tickera_event",
      "source_status" => "publish",
      "source_updated_at" => nil,
      "starts_at" => nil,
      "ends_at" => nil,
      "venue_name" => nil,
      "booking_fee_type" => nil,
      "booking_fee_value" => nil
    }
  end

  defp ticket_create(id) do
    %{
      "action" => "create",
      "ref" => "ticket:#{id}",
      "event_ref" => "event:1",
      "name" => "Ticket #{id}",
      "active" => true,
      "external_ticket_type_id" => id,
      "external_ticket_type_kind" => "woo_product",
      "external_product_id" => id,
      "external_variation_id" => nil,
      "source_status" => "publish",
      "source_updated_at" => nil
    }
  end

  defp mapping_create(id) do
    %{
      "action" => "create",
      "event_ref" => "event:1",
      "ticket_type_ref" => "ticket:#{id}",
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "woo_product_id" => id,
      "woo_variation_id" => nil,
      "original_label" => "Ticket #{id}",
      "current_label" => "Ticket #{id}",
      "active" => true
    }
  end

  defp finding(severity, id) do
    %{
      "severity" => severity,
      "code" => "missing_source_risk_data",
      "target_type" => "product",
      "target_id" => id,
      "context" => %{}
    }
  end

  defp risk(target_type, id) do
    %{
      "target_type" => target_type,
      "target_id" => id,
      "code" => "missing_source_risk_data",
      "evidence_classification" => "missing",
      "evidence_source" => "planner_identity_query",
      "evidence_value" => nil
    }
  end

  defp destination(id) do
    %{
      "woo_product_id" => id,
      "woo_variation_id" => nil,
      "proposed_event_external_id" => 1,
      "proposed_ticket_type_external_id" => id,
      "resolution" => "proposed",
      "pending_line_count" => 0,
      "quantity" => 0,
      "eligible_line_count" => 0,
      "deferred_line_count" => 0,
      "conflicting_line_count" => 0,
      "conflicting_quantity" => 0,
      "already_mapped_line_count" => 0,
      "already_mapped_quantity" => 0,
      "unknown_classification_count" => 0
    }
  end

  defp event_proof(id) do
    %{
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "external_event_kind" => "tickera_event",
      "external_event_id" => id,
      "event_id" => nil,
      "action" => "create",
      "no_mutation" => false
    }
  end

  defp ticket_proof(id) do
    %{
      "external_ticket_type_kind" => "woo_product",
      "external_ticket_type_id" => id,
      "external_product_id" => id,
      "external_variation_id" => nil,
      "ticket_type_id" => nil,
      "event_id" => nil,
      "event_ref" => "event:1",
      "action" => "create",
      "no_mutation" => false
    }
  end

  defp mapping_proof(id) do
    %{
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "woo_product_id" => id,
      "woo_variation_id" => nil,
      "event_ref" => "event:1",
      "ticket_type_ref" => "ticket:#{id}",
      "action" => "create",
      "no_existing_conflict" => true,
      "no_movement" => true
    }
  end
end
