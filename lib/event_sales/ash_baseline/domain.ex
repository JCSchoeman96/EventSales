defmodule EventSales.AshBaseline.Domain do
  @moduledoc """
  Proof-only Ash domain for Slice 0.4 ecosystem baseline checks.

  This domain is intentionally isolated from the future business domains and
  only exists to prove the selected Ash extensions integrate with this repo.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show?(true)
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource EventSales.AshBaseline.Resources.AuthUser
    resource EventSales.AshBaseline.Resources.StateMachineProof
    resource EventSales.AshBaseline.Resources.PaperTrailProof
  end
end
