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

  test "in-progress and terminal U states contain exactly one continuation field" do
    assert {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata())
    assert {:ok, pending} = HistoricalCatchupEvidence.from_page(catchup_page(), parent)

    in_progress_metadata =
      HistoricalCatchupEvidence.in_progress_metadata(pending, "cursor-a.cursor-b")

    assert HistoricalCatchupEvidence.state(in_progress_metadata) == :catchup_in_progress
    assert {:ok, in_progress} = HistoricalCatchupEvidence.from_metadata(in_progress_metadata)
    assert in_progress.next_cursor == "cursor-a.cursor-b"
    assert is_nil(in_progress.terminal_evidence)

    assert Map.keys(in_progress_metadata["historical_catchup"]) |> Enum.sort() ==
             [
               "boundary_token",
               "manifest_expires_at_gmt",
               "manifest_hash",
               "next_cursor",
               "phase",
               "schema_version",
               "source_observed_at_gmt",
               "state"
             ]

    terminal_metadata =
      HistoricalCatchupEvidence.terminal_metadata(pending, "u-terminal-proof")

    assert HistoricalCatchupEvidence.state(terminal_metadata) == :catchup_terminal
    assert {:ok, terminal} = HistoricalCatchupEvidence.from_metadata(terminal_metadata)
    assert terminal.terminal_evidence == "u-terminal-proof"
    assert is_nil(terminal.next_cursor)

    assert Map.keys(terminal_metadata["historical_catchup"]) |> Enum.sort() ==
             [
               "boundary_token",
               "manifest_expires_at_gmt",
               "manifest_hash",
               "phase",
               "schema_version",
               "source_observed_at_gmt",
               "state",
               "terminal_evidence"
             ]

    assert HistoricalCatchupEvidence.from_metadata(%{
             "historical_catchup" =>
               Map.merge(
                 in_progress_metadata["historical_catchup"],
                 %{"terminal_evidence" => "forbidden"}
               )
           }) == {:error, :invalid_catchup_evidence}
  end

  test "validates immutable U page continuity and explicit terminal proof" do
    assert {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata())
    assert {:ok, pending} = HistoricalCatchupEvidence.from_page(catchup_page(), parent)

    page =
      catchup_page()
      |> Map.put("items", [catchup_item("901")])
      |> Map.put("has_more", true)
      |> Map.put("next_cursor", "cursor-a.cursor-b")
      |> Map.delete("terminal_evidence")

    assert HistoricalCatchupEvidence.validate_continuity(pending, page) == :ok

    assert HistoricalCatchupEvidence.validate_continuity(
             pending,
             Map.put(page, "manifest_hash", @parent_hash)
           ) == {:error, :catchup_continuity_mismatch}

    assert HistoricalCatchupEvidence.from_page(
             Map.delete(catchup_page(), "terminal_evidence"),
             parent
           ) == {:error, :invalid_catchup_page}

    assert {:ok, terminal} =
             HistoricalCatchupEvidence.from_metadata(
               HistoricalCatchupEvidence.terminal_metadata(pending, "u-terminal-proof")
             )

    assert DateTime.compare(terminal.source_observed_at, @parent_observed_at) in [:eq, :gt]
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

    {:ok, pending} = HistoricalCatchupEvidence.from_metadata(pending_metadata)
    max_cursor = String.duplicate("a", 510) <> ".b"
    max_terminal_evidence = String.duplicate("u", 512)

    in_progress_metadata =
      Map.merge(
        parent_metadata,
        HistoricalCatchupEvidence.in_progress_metadata(pending, max_cursor)
      )

    terminal_metadata =
      Map.merge(
        parent_metadata,
        HistoricalCatchupEvidence.terminal_metadata(pending, max_terminal_evidence)
      )

    assert {:ok, in_progress_size} = HistoricalCatchupEvidence.encoded_size(in_progress_metadata)
    assert {:ok, terminal_size} = HistoricalCatchupEvidence.encoded_size(terminal_metadata)
    assert in_progress_size <= HistoricalCatchupEvidence.metadata_max_bytes()
    assert terminal_size <= HistoricalCatchupEvidence.metadata_max_bytes()
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

  defp catchup_item(order_id) do
    %{
      "source_order_id" => order_id,
      "source_created_at_gmt" => "2026-08-13T12:01:00.000000Z",
      "source_modified_at_gmt" => "2026-08-13T12:02:00.000000Z"
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
