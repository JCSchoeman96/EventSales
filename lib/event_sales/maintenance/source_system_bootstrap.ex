defmodule EventSales.Maintenance.SourceSystemBootstrap do
  @moduledoc """
  Idempotently provisions the active WooCommerce source required by webhook intake.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem

  @name_key "EVENTSALES_BOOTSTRAP_SOURCE_NAME"
  @base_url_key "EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL"

  @spec run!(map() | keyword()) :: %{name: String.t(), status: :created | :existing | :updated}
  def run!(env \\ System.get_env()) do
    env = Map.new(env)
    name = required_env!(env, @name_key)
    base_url = env |> required_env!(@base_url_key) |> normalize_base_url()

    case source_by_base_url(base_url) do
      nil ->
        Ash.create!(
          SourceSystem,
          %{name: name, kind: :woocommerce, base_url: base_url, active: true},
          action: :create,
          domain: Catalog
        )

        %{name: name, status: :created}

      %SourceSystem{name: ^name, active: true} ->
        %{name: name, status: :existing}

      %SourceSystem{} = source ->
        Ash.update!(
          source,
          %{name: name, active: true},
          action: :update,
          domain: Catalog
        )

        %{name: name, status: :updated}
    end
  end

  defp required_env!(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise(ArgumentError, "#{key} is required"), else: value

      _ ->
        raise ArgumentError, "#{key} is required"
    end
  end

  defp normalize_base_url(url), do: url |> String.trim() |> String.trim_trailing("/")

  defp source_by_base_url(base_url) do
    SourceSystem
    |> Ash.Query.filter(kind == :woocommerce and base_url == ^base_url)
    |> Ash.read_one!(domain: Catalog)
  end
end
