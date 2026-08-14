defmodule EventSales.Ingestion.HistoricalCatchupEvidenceTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalManifestEvidence

  @parent_token "parent-manifest-token"
  @child_token "child-manifest-token"
  @parent_hash String.duplicate("a", 64)
  @child_hash String.duplicate("b", 64)
  @parent_observed_at ~U[2026-08-13 11:00:00.000000Z]

  test "builds bounded pending child evidence from a terminal parent" do
    assert {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata())
    assert {:ok, evidence} = HistoricalCatchupEvidence.from_page(catchup_page(), parent)

    assert evidence.state == "pending_first_page"
    assert evidence.boundary_token == @child_token
    assert evidence.manifest_hash == @child_hash
    assert evidence.source_observed_at == ~U[2026-08-13 12:00:00.000000Z]

    assert HistoricalCatchupEvidence.metadata(evidence) == %{
             "historical_catchup" => %{
               "schema_version" => "2026-08-13.catchup.v1",
               "phase" => "catch_up",
               "boundary_token" => @child_token,
               "manifest_hash" => @child_hash,
               "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
               "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
               "state" => "pending_first_page"
             }
           }
  end

  test "claim and pending states are strict sibling namespaces" do
    assert HistoricalCatchupEvidence.state(%{}) == :missing

    assert HistoricalCatchupEvidence.state(HistoricalCatchupEvidence.claim_metadata()) ==
             :create_claimed

    assert {:ok, pending} =
             HistoricalCatchupEvidence.from_metadata(%{
               "historical_catchup" => %{
                 "schema_version" => "2026-08-13.catchup.v1",
                 "phase" => "catch_up",
                 "boundary_token" => @child_token,
                 "manifest_hash" => @child_hash,
                 "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
                 "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
                 "state" => "pending_first_page"
               }
             })

    assert pending.state == "pending_first_page"

    assert HistoricalCatchupEvidence.state(%{
             "historical_catchup" => %{
               "state" => "pending_first_page",
               "parent_manifest_hash" => @parent_hash
             }
           }) == :corrupt
  end

  test "maximum parent evidence plus catch-up states fit the 2048-byte cursor bound" do
    parent_metadata = max_parent_metadata()
    assert {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata)
    assert {:ok, child} = HistoricalCatchupEvidence.from_page(max_catchup_page(), parent)

    claim_metadata = Map.merge(parent_metadata, HistoricalCatchupEvidence.claim_metadata())
    pending_metadata = Map.merge(parent_metadata, HistoricalCatchupEvidence.metadata(child))

    assert {:ok, claim_size} = HistoricalCatchupEvidence.encoded_size(claim_metadata)
    assert {:ok, pending_size} = HistoricalCatchupEvidence.encoded_size(pending_metadata)
    assert claim_size <= HistoricalCatchupEvidence.metadata_max_bytes()
    assert pending_size <= HistoricalCatchupEvidence.metadata_max_bytes()

    future_cursor = String.duplicate("a", 510) <> ".b"

    future_metadata =
      Map.update!(
        pending_metadata,
        "historical_catchup",
        &Map.put(&1, "next_cursor", future_cursor)
      )

    assert {:ok, future_size} = HistoricalCatchupEvidence.encoded_size(future_metadata)
    assert future_size <= HistoricalCatchupEvidence.metadata_max_bytes()
  end

  defp parent_metadata do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => @parent_token,
        "manifest_hash" => @parent_hash,
        "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
        "source_observed_at_gmt" => DateTime.to_iso8601(@parent_observed_at),
        "state" => "manifest_terminal",
        "terminal_evidence" => "parent-terminal-proof"
      }
    }
  end

  defp catchup_page do
    %{
      "schema_version" => "2026-08-13.catchup.v1",
      "phase" => "catch_up",
      "boundary_token" => @child_token,
      "manifest_hash" => @child_hash,
      "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
      "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
      "items" => [],
      "has_more" => false,
      "terminal_evidence" => "child-terminal-proof"
    }
  end

  defp max_parent_metadata do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => String.duplicate("p", 128),
        "manifest_hash" => @parent_hash,
        "manifest_expires_at_gmt" => "2026-08-14T13:00:00.000000Z",
        "source_observed_at_gmt" => DateTime.to_iso8601(@parent_observed_at),
        "state" => "manifest_terminal",
        "terminal_evidence" => String.duplicate("t", 512)
      }
    }
  end

  defp max_catchup_page do
    %{
      "schema_version" => "2026-08-13.catchup.v1",
      "phase" => "catch_up",
      "boundary_token" => String.duplicate("c", 128),
      "manifest_hash" => @child_hash,
      "manifest_expires_at_gmt" => "2026-08-14T14:00:00.000000Z",
      "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
      "items" => [],
      "has_more" => false,
      "terminal_evidence" => String.duplicate("u", 512)
    }
  end
end
