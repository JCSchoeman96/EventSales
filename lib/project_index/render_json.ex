defmodule ProjectIndex.RenderJson do
  @moduledoc false

  def render_module_manifest(result) do
    %{
      schema_version: result.schema_version,
      generator: result.generator,
      root: result.root,
      files: result.files,
      modules: result.modules
    }
    |> canonicalize()
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
    |> ensure_trailing_newline()
  end

  def render_domain_map(result) do
    %{
      schema_version: result.schema_version,
      generator: result.generator,
      root: result.root,
      ash: result.ash,
      phoenix: result.phoenix,
      oban: result.oban
    }
    |> canonicalize()
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
    |> ensure_trailing_newline()
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_key_string(key), canonicalize(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp to_key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key_string(key) when is_binary(key), do: key

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
