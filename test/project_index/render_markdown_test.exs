defmodule ProjectIndex.RenderMarkdownTest do
  use ExUnit.Case, async: true

  @tag :project_index
  test "renders required deterministic index sections" do
    markdown = ProjectIndex.RenderMarkdown.render(sample_result())

    assert markdown =~ "# INDEX"
    assert markdown =~ "Schema version: `1`"
    assert markdown =~ "Generator: `mix project.index`"
    assert markdown =~ "## Files"
    assert markdown =~ "- `lib/event_sales/catalog/resources/event.ex`"
    assert markdown =~ "## Modules"
    assert markdown =~ "`EventSales.Catalog.Resources.Event`"
    assert markdown =~ "## Ash"
    assert markdown =~ "### Resources"
    assert markdown =~ "## Phoenix"
    assert markdown =~ "### LiveViews"
    assert markdown =~ "## Oban"
    refute markdown =~ "Generated:"
  end

  defp sample_result do
    module = %{
      name: "EventSales.Catalog.Resources.Event",
      path: "lib/event_sales/catalog/resources/event.ex",
      parse_error: nil,
      moduledoc?: true,
      specs?: true,
      docs_count: 1,
      public_funs: [%{name: "read", arity: 0}],
      uses: ["Ash.Resource"]
    }

    %{
      schema_version: 1,
      generator: "mix project.index",
      root: ".",
      files: ["lib/event_sales/catalog/resources/event.ex"],
      modules: [module],
      ash: %{
        resources: [module],
        domains: [],
        changes: [],
        validations: [],
        calculations: [],
        policies: []
      },
      phoenix: %{live_views: [], controllers: [], components: [], routers: [], plugs: []},
      oban: %{workers: []}
    }
  end
end
