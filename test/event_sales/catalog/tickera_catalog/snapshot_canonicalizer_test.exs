defmodule EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizerTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer

  @keys ~w(
    snapshot_schema_version source_system_id origin event_actions
    ticket_type_actions product_mapping_actions findings source_risks
    historical_impact identity_membership_proof touched_identifiers
  )

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
      |> put_in(["event_actions"], [
        %{
          "action" => "update_metadata",
          "booking_fee_value" => Decimal.new("-0.000"),
          "source_updated_at" => ~U[2026-07-22 10:00:00.123456Z]
        }
      ])

    assert {:ok, bytes, _hash} = canonicalize(snapshot)
    assert bytes =~ ~s("booking_fee_value":"0")
    assert bytes =~ ~s("source_updated_at":"2026-07-22T10:00:00.123456Z")
  end

  defp canonicalize(snapshot), do: SnapshotCanonicalizer.canonicalize(snapshot)

  defp valid_snapshot do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => "00000000-0000-0000-0000-000000000001",
      "origin" => "targeted_catalog_change",
      "event_actions" => [],
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
end
