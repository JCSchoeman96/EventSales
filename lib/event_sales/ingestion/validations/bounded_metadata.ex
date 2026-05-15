defmodule EventSales.Ingestion.Validations.BoundedMetadata do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    metadata = Ash.Changeset.get_argument_or_attribute(changeset, :metadata) || %{}

    case Jason.encode(metadata) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes ->
        :ok

      {:ok, _} ->
        {:error, field: :metadata, message: "metadata exceeds maximum size of #{max_bytes} bytes"}

      {:error, _} ->
        {:error, field: :metadata, message: "metadata must be JSON-encodable"}
    end
  end
end
