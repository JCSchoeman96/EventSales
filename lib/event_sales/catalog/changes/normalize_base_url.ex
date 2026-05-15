defmodule EventSales.Catalog.Changes.NormalizeBaseUrl do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :base_url) do
      nil ->
        changeset

      url when is_binary(url) ->
        Ash.Changeset.force_change_attribute(changeset, :base_url, normalize_url(url))
    end
  end

  defp normalize_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end
end
