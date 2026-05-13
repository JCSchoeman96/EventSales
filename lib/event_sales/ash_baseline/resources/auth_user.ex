defmodule EventSales.AshBaseline.Resources.AuthUser do
  @moduledoc """
  Proof-only authentication resource for Slice 0.4.

  This module intentionally does not replace the future Accounts user resource.
  It exists only to prove that AshAuthentication can be configured against an
  AshPostgres-backed resource in this repository.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.AshBaseline.Domain,
    extensions: [AshAuthentication]

  postgres do
    table "ash_baseline_auth_users"
    repo EventSales.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
      public? false
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  authentication do
    strategies do
      password :password do
        identity_field :email
        sign_in_enabled? false
        sign_in_tokens_enabled? false
      end
    end
  end
end
