defmodule EventSales.Ingestion.Validations.AuthorizedTickeraStateMutation do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    if authorized?(context) or authorized?(Map.get(changeset, :context, %{})) do
      :ok
    else
      {:error, message: "tickera state mutation is not authorized"}
    end
  end

  defp authorized?(%{tickera_state_authorized?: true}), do: true
  defp authorized?(%{tickera_state_authorized: true}), do: true
  defp authorized?(%{private: %{tickera_state_authorized?: true}}), do: true
  defp authorized?(%{private: %{tickera_state_authorized: true}}), do: true
  defp authorized?(%{public: %{tickera_state_authorized?: true}}), do: true
  defp authorized?(%{public: %{tickera_state_authorized: true}}), do: true
  defp authorized?(_context), do: false
end
