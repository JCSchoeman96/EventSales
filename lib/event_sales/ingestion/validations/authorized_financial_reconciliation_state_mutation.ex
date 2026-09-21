defmodule EventSales.Ingestion.Validations.AuthorizedFinancialReconciliationStateMutation do
  @moduledoc """
  Prevents accidental direct Ash writes to financial reconciliation state resources.

  This is an application-internal guard, not a security boundary. Facade
  authorization (`actor`, `internal?`) remains the real access control.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    if authorized?(context) or authorized?(Map.get(changeset, :context, %{})) do
      :ok
    else
      {:error, message: "financial reconciliation state mutation is not authorized"}
    end
  end

  defp authorized?(%{financial_reconciliation_state_authorized?: true}), do: true
  defp authorized?(%{financial_reconciliation_state_authorized: true}), do: true

  defp authorized?(%{private: %{financial_reconciliation_state_authorized?: true}}), do: true
  defp authorized?(%{private: %{financial_reconciliation_state_authorized: true}}), do: true
  defp authorized?(%{public: %{financial_reconciliation_state_authorized?: true}}), do: true
  defp authorized?(%{public: %{financial_reconciliation_state_authorized: true}}), do: true
  defp authorized?(_context), do: false
end
