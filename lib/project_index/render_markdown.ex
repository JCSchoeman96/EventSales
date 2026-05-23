defmodule ProjectIndex.RenderMarkdown do
  @moduledoc false

  def render(result) do
    [
      "# INDEX",
      "",
      "Schema version: `#{result.schema_version}`",
      "",
      "Generator: `#{result.generator}`",
      "",
      "Project root: `#{result.root}`",
      "",
      "## File Count",
      "",
      Integer.to_string(length(result.files)),
      "",
      "## Files",
      "",
      render_file_list(result.files),
      "",
      "## Modules",
      "",
      render_modules(result.modules),
      "",
      "## Ash",
      "",
      render_group("Resources", result.ash.resources),
      render_group("Domains", result.ash.domains),
      render_group("Changes", result.ash.changes),
      render_group("Validations", result.ash.validations),
      render_group("Calculations", result.ash.calculations),
      render_group("Policies", result.ash.policies),
      "## Phoenix",
      "",
      render_group("LiveViews", result.phoenix.live_views),
      render_group("Controllers", result.phoenix.controllers),
      render_group("Components", result.phoenix.components),
      render_group("Routers", result.phoenix.routers),
      render_group("Plugs", result.phoenix.plugs),
      "## Oban",
      "",
      render_group("Workers", result.oban.workers)
    ]
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  defp render_file_list([]), do: "_none_"

  defp render_file_list(files) do
    Enum.map_join(files, "\n", &"- `#{&1}`")
  end

  defp render_modules([]), do: "_none_"

  defp render_modules(modules) do
    Enum.map_join(modules, "\n", &render_module/1)
  end

  defp render_module(%{parse_error: parse_error} = module) when is_binary(parse_error) do
    "- `(parse error)` - `#{module.path}`\n  - parse_error: `#{escape_inline(parse_error)}`"
  end

  defp render_module(module) do
    [
      "- `#{module.name}` - `#{module.path}`",
      "  - moduledoc?: #{module.moduledoc?}",
      "  - specs?: #{module.specs?}",
      "  - docs_count: #{module.docs_count}",
      "  - public_funs: #{render_public_funs(module.public_funs)}",
      "  - uses: #{render_uses(module.uses)}"
    ]
    |> Enum.join("\n")
  end

  defp render_group(title, modules) do
    ["### #{title}", "", render_name_list(modules), ""]
    |> Enum.join("\n")
  end

  defp render_name_list([]), do: "_none_"

  defp render_name_list(modules) do
    Enum.map_join(modules, "\n", fn module ->
      "- `#{module.name || "(parse error)"}` - `#{module.path}`"
    end)
  end

  defp render_public_funs([]), do: "_none_"

  defp render_public_funs(functions) do
    Enum.map_join(functions, ", ", &"`#{&1.name}/#{&1.arity}`")
  end

  defp render_uses([]), do: "_none_"
  defp render_uses(uses), do: Enum.map_join(uses, ", ", &"`#{&1}`")

  defp escape_inline(value), do: String.replace(value, "`", "\\`")

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
