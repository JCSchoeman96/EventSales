defmodule ProjectIndex.Scanner do
  @moduledoc false

  alias ProjectIndex.ElixirFile

  @schema_version 1
  @generator "mix project.index"

  @scan_roots ~w(lib config rel test/support)

  @exclude_parts MapSet.new(~w(.git _build deps node_modules coverage cover .elixir_ls dist tmp))

  @generated_outputs MapSet.new([
                       "INDEX.md",
                       "docs/architecture/module_manifest.json",
                       "docs/architecture/domain_map.json"
                     ])

  def scan_project(root) do
    scan_root = Path.expand(root)
    files = all_files(scan_root)

    elixir_files =
      files
      |> Enum.filter(&String.ends_with?(&1, [".ex", ".exs"]))
      |> Enum.map(&Path.join(scan_root, &1))
      |> Enum.map(&ElixirFile.parse/1)
      |> Enum.map(&relativize_parsed_file(&1, scan_root))

    modules =
      elixir_files
      |> Enum.flat_map(& &1.modules)
      |> Enum.sort_by(&{&1.path, &1.name || ""})

    %{
      schema_version: @schema_version,
      generator: @generator,
      root: ".",
      files: files,
      modules: modules,
      ash: build_ash_map(modules),
      phoenix: build_phoenix_map(modules),
      oban: build_oban_map(modules)
    }
  end

  defp all_files(root) do
    @scan_roots
    |> Enum.map(&Path.join(root, &1))
    |> Enum.flat_map(&wildcard_files/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&excluded_relative?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp wildcard_files(path) do
    if File.exists?(path) do
      path
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end

  defp excluded_relative?(relative_path) do
    relative_path in @generated_outputs or
      relative_path
      |> Path.split()
      |> Enum.any?(&MapSet.member?(@exclude_parts, &1))
  end

  defp relativize_parsed_file(%{path: path, modules: modules}, root) do
    relative_path = path |> Path.relative_to(root) |> normalize_path()

    modules =
      Enum.map(modules, fn module ->
        %{module | path: relative_path}
      end)

    %{path: relative_path, modules: modules}
  end

  defp build_ash_map(modules) do
    %{
      resources: filter_by_use(modules, "Ash.Resource"),
      domains: filter_by_use(modules, "Ash.Domain"),
      changes: filter_by_use_or_path(modules, ["Ash.Resource.Change"], "/changes/"),
      validations: filter_by_use_or_path(modules, ["Ash.Resource.Validation"], "/validations/"),
      calculations:
        filter_by_use_or_path(modules, ["Ash.Resource.Calculation"], "/calculations/"),
      policies: filter_by_path(modules, "/policies/")
    }
  end

  defp build_phoenix_map(modules) do
    %{
      live_views:
        Enum.filter(modules, fn module ->
          used?(module, "Phoenix.LiveView") or uses_event_sales_web_role?(module, ":live_view")
        end),
      controllers:
        Enum.filter(modules, fn module ->
          used?(module, "Phoenix.Controller") or uses_event_sales_web_role?(module, ":controller")
        end),
      components: filter_by_use(modules, "Phoenix.Component"),
      routers: filter_by_use(modules, "Phoenix.Router"),
      plugs:
        Enum.filter(modules, fn module ->
          used?(module, "Plug.Builder") or used?(module, "Plug.Conn") or
            path_contains?(module, "/plugs/")
        end)
    }
  end

  defp build_oban_map(modules), do: %{workers: filter_by_use(modules, "Oban.Worker")}

  defp filter_by_use(modules, use_target), do: Enum.filter(modules, &used?(&1, use_target))

  defp filter_by_use_or_path(modules, use_targets, path_fragment) do
    Enum.filter(modules, fn module ->
      Enum.any?(use_targets, &used?(module, &1)) or path_contains?(module, path_fragment)
    end)
  end

  defp filter_by_path(modules, path_fragment),
    do: Enum.filter(modules, &path_contains?(&1, path_fragment))

  defp used?(module, use_target), do: use_target in module.uses

  defp uses_event_sales_web_role?(module, role) do
    used?(module, "EventSalesWeb") and String.contains?(module.path, role_path_fragment(role))
  end

  defp role_path_fragment(":live_view"), do: "/live/"
  defp role_path_fragment(":controller"), do: "/controllers/"

  defp path_contains?(module, path_fragment),
    do: String.contains?("/" <> module.path, path_fragment)

  defp normalize_path(path), do: String.replace(path, "\\", "/")
end
