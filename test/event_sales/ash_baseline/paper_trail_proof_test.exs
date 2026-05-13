defmodule EventSales.AshBaseline.PaperTrailProofTest do
  use EventSales.DataCase, async: true

  alias EventSales.AshBaseline.Domain
  alias EventSales.AshBaseline.Resources.PaperTrailProof

  test "updating the proof resource creates a paper trail version" do
    assert Code.ensure_loaded?(PaperTrailProof)

    proof = Ash.create!(PaperTrailProof, %{title: "before"}, domain: Domain)
    updated = Ash.update!(proof, %{title: "after"}, domain: Domain)
    loaded = Ash.load!(updated, :paper_trail_versions, domain: Domain)

    assert length(loaded.paper_trail_versions) == 1

    version = hd(loaded.paper_trail_versions)

    assert version.version_action_type == :update
    assert version.changes["title"] == "after"
  end
end
