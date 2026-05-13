defmodule EventSales.AshBaseline.StateMachineProofTest do
  use EventSales.DataCase, async: true

  alias EventSales.AshBaseline.Domain
  alias EventSales.AshBaseline.Resources.StateMachineProof

  test "valid transition succeeds" do
    assert Code.ensure_loaded?(StateMachineProof)

    proof = Ash.create!(StateMachineProof, %{name: "proof"}, domain: Domain)

    assert proof.state == :draft

    activated = Ash.update!(proof, %{}, action: :activate, domain: Domain)

    assert activated.state == :active
  end

  test "invalid transition is rejected" do
    assert Code.ensure_loaded?(StateMachineProof)

    proof = Ash.create!(StateMachineProof, %{name: "proof"}, domain: Domain)

    assert {:error, _error} = Ash.update(proof, %{}, action: :archive, domain: Domain)
  end
end
