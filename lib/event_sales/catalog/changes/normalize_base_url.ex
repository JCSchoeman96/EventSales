defmodule EventSales.Catalog.Changes.NormalizeBaseUrl do
  @moduledoc """
  Persisted `SourceSystem.base_url` normalization for canonical_source_key.

  Trim whitespace and trailing `/` only. This is distinct from
  DiscoveryIntegrity URI normalization used for producer wire IDs (M1-02).
  """

  use Ash.Resource.Change

  @doc """
  Applies the persisted SourceSystem base_url normalization rules.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :base_url) do
      nil ->
        changeset

      url when is_binary(url) ->
        Ash.Changeset.force_change_attribute(changeset, :base_url, normalize(url))
    end
  end
end
