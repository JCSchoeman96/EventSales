defmodule EventSales.AshBaseline.AuthUserSupportTest do
  use EventSales.DataCase, async: true

  alias EventSales.AshBaseline.Domain
  alias EventSales.AshBaseline.Resources.AuthUser

  test "auth user proof resource is registered and exposes the password strategy" do
    assert Code.ensure_loaded?(Domain)
    assert Code.ensure_loaded?(AuthUser)

    assert AuthUser in Ash.Domain.Info.resources(Domain)
    assert {:ok, Domain} = AshAuthentication.Info.domain(AuthUser)
    assert AshAuthentication.Info.strategy_present?(AuthUser, :password)
  end

  test "auth user proof resource can persist a minimal record" do
    assert Code.ensure_loaded?(AuthUser)

    email = "proof-#{System.unique_integer([:positive])}@example.com"

    auth_user =
      Ash.create!(
        AuthUser,
        %{
          email: email,
          password: "proof-pass-123",
          password_confirmation: "proof-pass-123"
        },
        action: :register_with_password,
        domain: Domain
      )

    assert auth_user.id
    assert auth_user.email == email
  end
end
