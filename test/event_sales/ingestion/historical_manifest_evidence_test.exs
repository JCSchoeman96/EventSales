defmodule EventSales.Ingestion.HistoricalManifestEvidenceTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.HistoricalManifestEvidence

  @boundary_token "manifest-token"
  @manifest_hash String.duplicate("a", 64)

  test "classifies the four durable manifest states" do
    assert HistoricalManifestEvidence.state(%{}) == :missing

    assert HistoricalManifestEvidence.state(HistoricalManifestEvidence.claim_metadata()) ==
             :create_claimed

    assert HistoricalManifestEvidence.state(pending_metadata()) == :pending_first_page
    assert HistoricalManifestEvidence.state(in_progress_metadata()) == :manifest_in_progress
    assert HistoricalManifestEvidence.state(terminal_metadata()) == :manifest_terminal
  end

  test "parses pending, in-progress, and terminal metadata with exact state keys" do
    assert {:ok, pending} = HistoricalManifestEvidence.from_metadata(pending_metadata())
    assert pending.state == "pending_first_page"
    assert pending.next_cursor == nil
    assert pending.terminal_evidence == nil

    assert {:ok, in_progress} = HistoricalManifestEvidence.from_metadata(in_progress_metadata())
    assert in_progress.state == "manifest_in_progress"
    assert in_progress.next_cursor == "opaque.next"
    assert in_progress.terminal_evidence == nil

    assert {:ok, terminal} = HistoricalManifestEvidence.from_metadata(terminal_metadata())
    assert terminal.state == "manifest_terminal"
    assert terminal.next_cursor == nil
    assert terminal.terminal_evidence == "terminal-proof"

    assert {:error, :invalid_manifest_evidence} =
             HistoricalManifestEvidence.from_metadata(
               put_namespace(in_progress_metadata(), "terminal_evidence", "unexpected")
             )

    assert {:error, :invalid_manifest_evidence} =
             HistoricalManifestEvidence.from_metadata(
               put_namespace(terminal_metadata(), "next_cursor", "opaque.next")
             )

    assert {:error, :invalid_manifest_evidence} =
             HistoricalManifestEvidence.from_metadata(
               put_namespace(pending_metadata(), "next_cursor", "opaque.next")
             )
  end

  test "state-specific constructors contain only their permitted additions" do
    {:ok, evidence} = HistoricalManifestEvidence.from_metadata(pending_metadata())

    assert %{"historical_manifest" => in_progress} =
             HistoricalManifestEvidence.in_progress_metadata(evidence, "opaque.next")

    assert Map.keys(in_progress) |> MapSet.new() ==
             MapSet.new([
               "schema_version",
               "phase",
               "boundary_token",
               "manifest_hash",
               "manifest_expires_at_gmt",
               "source_observed_at_gmt",
               "state",
               "next_cursor"
             ])

    assert in_progress["state"] == "manifest_in_progress"
    assert in_progress["next_cursor"] == "opaque.next"

    assert %{"historical_manifest" => terminal} =
             HistoricalManifestEvidence.terminal_metadata(evidence, "terminal-proof")

    assert Map.keys(terminal) |> MapSet.new() ==
             MapSet.new([
               "schema_version",
               "phase",
               "boundary_token",
               "manifest_hash",
               "manifest_expires_at_gmt",
               "source_observed_at_gmt",
               "state",
               "terminal_evidence"
             ])

    assert terminal["state"] == "manifest_terminal"
    assert terminal["terminal_evidence"] == "terminal-proof"
  end

  test "failure evidence preserves the manifest namespace and remains bounded" do
    metadata = in_progress_metadata()

    assert {:ok, failed} = HistoricalManifestEvidence.with_failure(metadata, "audit_failed")
    assert failed["historical_manifest"] == metadata["historical_manifest"]
    assert failed["failure"] == "audit_failed"
    assert {:ok, size} = HistoricalManifestEvidence.encoded_size(failed)
    assert size <= HistoricalManifestEvidence.metadata_max_bytes()
  end

  test "all canonical states remain within the metadata bound" do
    for metadata <- [
          HistoricalManifestEvidence.claim_metadata(),
          pending_metadata(),
          in_progress_metadata(),
          terminal_metadata()
        ] do
      assert {:ok, size} = HistoricalManifestEvidence.encoded_size(metadata)
      assert size <= HistoricalManifestEvidence.metadata_max_bytes()
    end
  end

  defp pending_metadata do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => @boundary_token,
        "manifest_hash" => @manifest_hash,
        "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
        "source_observed_at_gmt" => "2026-08-13T11:00:00.000000Z",
        "state" => "pending_first_page"
      }
    }
  end

  defp in_progress_metadata do
    put_namespace(pending_metadata(), "state", "manifest_in_progress")
    |> put_namespace("next_cursor", "opaque.next")
  end

  defp terminal_metadata do
    put_namespace(pending_metadata(), "state", "manifest_terminal")
    |> put_namespace("terminal_evidence", "terminal-proof")
  end

  defp put_namespace(metadata, key, value) do
    update_in(metadata, ["historical_manifest"], &Map.put(&1, key, value))
  end
end
