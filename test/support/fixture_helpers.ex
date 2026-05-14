defmodule EventSales.TestSupport.FixtureHelpers do
  @moduledoc """
  Test-only fixture helpers for Slice 1.5 acceptance harnesses.
  """

  @type fixture_group :: :woocommerce

  @spec fixture_path!(fixture_group(), atom() | String.t()) :: String.t()
  def fixture_path!(:woocommerce, fixture_name) do
    Path.expand("../fixtures/woocommerce/#{normalize_fixture_name(fixture_name)}", __DIR__)
  end

  @spec read_fixture!(fixture_group(), atom() | String.t()) :: String.t()
  def read_fixture!(fixture_group, fixture_name) do
    fixture_group
    |> fixture_path!(fixture_name)
    |> File.read!()
  end

  @spec decode_json_fixture!(fixture_group(), atom() | String.t()) :: map()
  def decode_json_fixture!(fixture_group, fixture_name) do
    fixture_group
    |> read_fixture!(fixture_name)
    |> Jason.decode!()
  end

  defp normalize_fixture_name(fixture_name) when is_atom(fixture_name) do
    fixture_name
    |> Atom.to_string()
    |> normalize_fixture_name()
  end

  defp normalize_fixture_name(fixture_name) when is_binary(fixture_name) do
    if Path.extname(fixture_name) == "" do
      fixture_name <> ".json"
    else
      fixture_name
    end
  end
end
