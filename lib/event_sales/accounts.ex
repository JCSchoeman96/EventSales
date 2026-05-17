defmodule EventSales.Accounts do
  @moduledoc """
  Ash domain boundary for users, authentication, roles, event access, and PII visibility.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  admin do
    show?(true)

    show_resources([
      EventSales.Accounts.Resources.User,
      EventSales.Accounts.Resources.Role,
      EventSales.Accounts.Resources.UserRole,
      EventSales.Accounts.Resources.EventAccessGrant
    ])
  end

  resources do
    resource EventSales.Accounts.Resources.User
    resource EventSales.Accounts.Resources.Role
    resource EventSales.Accounts.Resources.UserRole
    resource EventSales.Accounts.Resources.EventAccessGrant
  end
end
