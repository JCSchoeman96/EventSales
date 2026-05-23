defmodule Mix.Tasks.Project.Index do
  @moduledoc """
  Generates deterministic project index artifacts.

      mix project.index
      mix project.index --check
  """

  use Mix.Task

  @shortdoc "Generates INDEX.md and project architecture JSON manifests"

  @outputs [
    {"INDEX.md", &ProjectIndex.RenderMarkdown.render/1},
    {"docs/architecture/module_manifest.json", &ProjectIndex.RenderJson.render_module_manifest/1},
    {"docs/architecture/domain_map.json", &ProjectIndex.RenderJson.render_domain_map/1}
  ]

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)
    result = ProjectIndex.Scanner.scan_project(File.cwd!())

    outputs =
      Enum.map(@outputs, fn {path, renderer} ->
        {path, renderer.(result)}
      end)

    if opts[:check] do
      check_outputs(outputs)
    else
      write_outputs(outputs)
    end
  end

  defp parse_args(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    opts
  end

  defp write_outputs(outputs) do
    Enum.each(outputs, fn {path, content} ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      Mix.shell().info("wrote #{path}")
    end)
  end

  defp check_outputs(outputs) do
    stale_outputs =
      Enum.filter(outputs, fn {path, content} ->
        case File.read(path) do
          {:ok, existing} -> existing != content
          {:error, _reason} -> true
        end
      end)

    if stale_outputs == [] do
      Mix.shell().info("project index is up to date")
    else
      paths = Enum.map_join(stale_outputs, "\n", fn {path, _content} -> "stale: #{path}" end)
      Mix.raise("project index is stale\n" <> paths)
    end
  end
end
