defmodule ProjectIndex.RenderJsonTest do
  use ExUnit.Case, async: true

  @tag :project_index
  test "renders valid module manifest and domain map JSON" do
    result = sample_result()

    assert {:ok, module_manifest} =
             result
             |> ProjectIndex.RenderJson.render_module_manifest()
             |> Jason.decode()

    assert module_manifest["schema_version"] == 1
    assert module_manifest["generator"] == "mix project.index"
    assert [%{"name" => "EventSales.Catalog.Resources.Event"}] = module_manifest["modules"]

    assert {:ok, domain_map} =
             result
             |> ProjectIndex.RenderJson.render_domain_map()
             |> Jason.decode()

    assert get_in(domain_map, ["ash", "resources", Access.at(0), "name"]) ==
             "EventSales.Catalog.Resources.Event"

    assert get_in(domain_map, ["phoenix", "live_views", Access.at(0), "name"]) ==
             "EventSalesWeb.Admin.DashboardLive"

    assert get_in(domain_map, ["oban", "workers", Access.at(0), "name"]) ==
             "EventSales.Ingestion.Workers.ProcessWebhookWorker"
  end

  defp sample_result do
    module = %{
      name: "EventSales.Catalog.Resources.Event",
      path: "lib/event_sales/catalog/resources/event.ex",
      parse_error: nil,
      moduledoc?: true,
      specs?: false,
      docs_count: 1,
      public_funs: [%{name: "read", arity: 0}],
      uses: ["Ash.Resource"]
    }

    live_view = %{module | name: "EventSalesWeb.Admin.DashboardLive", uses: ["EventSalesWeb"]}

    worker = %{
      module
      | name: "EventSales.Ingestion.Workers.ProcessWebhookWorker",
        uses: ["Oban.Worker"]
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
      phoenix: %{live_views: [live_view], controllers: [], components: [], routers: [], plugs: []},
      oban: %{workers: [worker]}
    }
  end
end
