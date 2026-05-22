defmodule EventSalesWeb.Presenters.CustomerPresenter do
  @moduledoc """
  Pure presentation helpers for customer PII.

  Callers should compute PII visibility once per request/list and pass it in.
  This module does not query roles or durable state.
  """

  alias EventSales.Accounts.PiiPolicy

  @masked_name "Masked customer"
  @masked_email "m***@***"

  @type presentation :: %{
          customer_name: String.t() | nil,
          customer_email: String.t() | nil,
          pii_visibility: :full | :masked | :none
        }

  @spec present(map() | struct(), keyword()) :: presentation()
  def present(customer, opts) do
    visibility =
      Keyword.get_lazy(opts, :pii_visibility, fn ->
        PiiPolicy.customer_pii_visibility(Keyword.get(opts, :actor), opts)
      end)

    case visibility do
      :full ->
        %{
          customer_name: field(customer, :customer_name),
          customer_email: field(customer, :customer_email),
          pii_visibility: :full
        }

      :masked ->
        %{
          customer_name: @masked_name,
          customer_email: @masked_email,
          pii_visibility: :masked
        }

      _none ->
        %{
          customer_name: nil,
          customer_email: nil,
          pii_visibility: :none
        }
    end
  end

  defp field(customer, key) when is_map(customer), do: Map.get(customer, key)
end
