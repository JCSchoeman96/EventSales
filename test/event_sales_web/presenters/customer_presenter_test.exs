defmodule EventSalesWeb.Presenters.CustomerPresenterTest do
  use ExUnit.Case, async: true

  alias EventSalesWeb.Presenters.CustomerPresenter

  defmodule Customer do
    defstruct [:customer_name, :customer_email]
  end

  @customer %{
    customer_name: "Private Customer",
    customer_email: "private.customer@example.test"
  }

  test "full visibility returns customer name and email" do
    assert CustomerPresenter.present(@customer, pii_visibility: :full) == %{
             customer_name: "Private Customer",
             customer_email: "private.customer@example.test",
             pii_visibility: :full
           }
  end

  test "masked visibility returns deterministic non-reversible placeholders" do
    presentation = CustomerPresenter.present(@customer, pii_visibility: :masked)

    assert presentation == %{
             customer_name: "Masked customer",
             customer_email: "m***@***",
             pii_visibility: :masked
           }

    refute presentation.customer_email =~ "private"
    refute presentation.customer_email =~ "customer"
    refute presentation.customer_email =~ "example"
    refute presentation.customer_email =~ "test"
  end

  test "none visibility omits customer name and email" do
    assert CustomerPresenter.present(@customer, pii_visibility: :none) == %{
             customer_name: nil,
             customer_email: nil,
             pii_visibility: :none
           }
  end

  test "nil customer fields do not crash" do
    customer = %{customer_name: nil, customer_email: nil}

    assert CustomerPresenter.present(customer, pii_visibility: :full) == %{
             customer_name: nil,
             customer_email: nil,
             pii_visibility: :full
           }

    assert CustomerPresenter.present(customer, pii_visibility: :masked).customer_email ==
             "m***@***"
  end

  test "structs are supported without web or database coupling" do
    customer = %EventSalesWeb.Presenters.CustomerPresenterTest.Customer{
      customer_name: "Struct Customer",
      customer_email: "struct.customer@example.test"
    }

    assert CustomerPresenter.present(customer, pii_visibility: :full).customer_email ==
             "struct.customer@example.test"
  end
end
