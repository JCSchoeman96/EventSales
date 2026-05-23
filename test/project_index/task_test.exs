defmodule Mix.Tasks.Project.IndexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tag :project_index
  test "writes outputs and check mode passes when files match" do
    root = temp_root()
    write(root, "lib/sample.ex", "defmodule Sample do\nend\n")

    in_root(root, fn ->
      assert capture_io(fn -> Mix.Tasks.Project.Index.run([]) end) =~ "wrote INDEX.md"
      assert File.exists?("INDEX.md")
      assert File.exists?("docs/architecture/module_manifest.json")
      assert File.exists?("docs/architecture/domain_map.json")

      assert capture_io(fn -> Mix.Tasks.Project.Index.run(["--check"]) end) =~
               "project index is up to date"
    end)
  end

  @tag :project_index
  test "check mode raises when an output is stale" do
    root = temp_root()
    write(root, "lib/sample.ex", "defmodule Sample do\nend\n")

    in_root(root, fn ->
      capture_io(fn -> Mix.Tasks.Project.Index.run([]) end)
      File.write!("INDEX.md", "stale\n")

      assert_raise Mix.Error, ~r/project index is stale/, fn ->
        capture_io(fn -> Mix.Tasks.Project.Index.run(["--check"]) end)
      end
    end)
  end

  defp temp_root do
    root =
      Path.join(System.tmp_dir!(), "project-index-task-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp write(root, relative_path, content) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp in_root(root, fun) do
    previous = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(previous)
    end
  end
end
