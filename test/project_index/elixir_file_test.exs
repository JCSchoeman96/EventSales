defmodule ProjectIndex.ElixirFileTest do
  use ExUnit.Case, async: true

  @tag :project_index
  test "parses module metadata, docs, specs, public functions, and use targets" do
    path =
      write_temp_file("""
      defmodule EventSales.Sample do
        @moduledoc "Sample docs"
        use Ash.Resource,
          otp_app: :event_sales,
          domain: EventSales.Catalog

        @typedoc "Identifier"
        @type id :: integer()

        @doc "Lists things"
        @spec list(integer()) :: integer()
        def list(value), do: value

        def zero(), do: :ok
        defp hidden(), do: :hidden
      end
      """)

    assert %{path: ^path, modules: [module]} = ProjectIndex.ElixirFile.parse(path)

    assert module.name == "EventSales.Sample"
    assert module.path == path
    assert module.moduledoc? == true
    assert module.specs? == true
    assert module.docs_count == 2
    assert module.public_funs == [%{name: "list", arity: 1}, %{name: "zero", arity: 0}]
    assert module.uses == ["Ash.Resource"]
    assert module.parse_error == nil
  end

  @tag :project_index
  test "records parse errors without raising" do
    path = write_temp_file("defmodule Broken do\n  def nope(")

    assert %{path: ^path, modules: [module]} = ProjectIndex.ElixirFile.parse(path)

    assert module.name == nil
    assert module.path == path
    assert module.parse_error
    assert module.moduledoc? == false
    assert module.specs? == false
    assert module.docs_count == 0
    assert module.public_funs == []
    assert module.uses == []
  end

  @tag :project_index
  test "does not attribute nested module or defimpl functions to the outer module" do
    path =
      write_temp_file("""
      defmodule EventSales.Outer do
        def outer_fun(), do: :outer

        defmodule Inner do
          def inner_fun(), do: :inner
        end

        defimpl String.Chars do
          def to_string(value), do: inspect(value)
        end
      end
      """)

    assert %{modules: [outer, inner]} = ProjectIndex.ElixirFile.parse(path)

    assert outer.name == "EventSales.Outer"
    assert outer.public_funs == [%{name: "outer_fun", arity: 0}]

    assert inner.name == "Inner"
    assert inner.public_funs == [%{name: "inner_fun", arity: 0}]
  end

  defp write_temp_file(source) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "project-index-elixir-file-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)
    path
  end
end
