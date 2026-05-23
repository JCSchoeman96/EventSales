defmodule ProjectIndex.ScannerTest do
  use ExUnit.Case, async: true

  @tag :project_index
  test "scans configured source roots, excludes generated/build files, and sorts paths" do
    root = temp_root()

    write(root, "lib/z_module.ex", "defmodule ZModule do\nend\n")
    write(root, "config/config.exs", "import Config\n")
    write(root, "rel/overlays/bin/server", "#!/usr/bin/env bash\n")
    write(root, "test/support/support_module.ex", "defmodule SupportModule do\nend\n")
    write(root, "test/project_index/not_scanned_test.exs", "defmodule NotScannedTest do\nend\n")
    write(root, "deps/dep.ex", "defmodule DepModule do\nend\n")
    write(root, "_build/dev/lib/generated.ex", "defmodule Generated do\nend\n")
    write(root, "INDEX.md", "# stale\n")
    write(root, "docs/architecture/module_manifest.json", "{}\n")
    write(root, "docs/architecture/domain_map.json", "{}\n")

    result = ProjectIndex.Scanner.scan_project(root)

    assert result.schema_version == 1
    assert result.generator == "mix project.index"
    assert result.root == "."

    assert result.files == [
             "config/config.exs",
             "lib/z_module.ex",
             "rel/overlays/bin/server",
             "test/support/support_module.ex"
           ]

    assert Enum.map(result.modules, & &1.name) == ["ZModule", "SupportModule"]
  end

  @tag :project_index
  test "classifies Ash, Phoenix, and Oban modules" do
    root = temp_root()

    write(root, "lib/event_sales/catalog/resources/event.ex", """
    defmodule EventSales.Catalog.Resources.Event do
      use Ash.Resource
    end
    """)

    write(root, "lib/event_sales/catalog.ex", """
    defmodule EventSales.Catalog do
      use Ash.Domain
    end
    """)

    write(root, "lib/event_sales/catalog/changes/example_change.ex", """
    defmodule EventSales.Catalog.Changes.ExampleChange do
      use Ash.Resource.Change
    end
    """)

    write(root, "lib/event_sales/ingestion/validations/example_validation.ex", """
    defmodule EventSales.Ingestion.Validations.ExampleValidation do
      use Ash.Resource.Validation
    end
    """)

    write(root, "lib/event_sales_web/live/admin/dashboard_live.ex", """
    defmodule EventSalesWeb.Admin.DashboardLive do
      use EventSalesWeb, :live_view
    end
    """)

    write(root, "lib/event_sales_web/controllers/page_controller.ex", """
    defmodule EventSalesWeb.PageController do
      use EventSalesWeb, :controller
    end
    """)

    write(root, "lib/event_sales_web/live/admin/components/stat_card.ex", """
    defmodule EventSalesWeb.Admin.Components.StatCard do
      use Phoenix.Component
    end
    """)

    write(root, "lib/event_sales/ingestion/workers/process_webhook_worker.ex", """
    defmodule EventSales.Ingestion.Workers.ProcessWebhookWorker do
      use Oban.Worker, queue: :default
    end
    """)

    result = ProjectIndex.Scanner.scan_project(root)

    assert names(result.ash.resources) == ["EventSales.Catalog.Resources.Event"]
    assert names(result.ash.domains) == ["EventSales.Catalog"]
    assert names(result.ash.changes) == ["EventSales.Catalog.Changes.ExampleChange"]
    assert names(result.ash.validations) == ["EventSales.Ingestion.Validations.ExampleValidation"]
    assert names(result.phoenix.live_views) == ["EventSalesWeb.Admin.DashboardLive"]
    assert names(result.phoenix.controllers) == ["EventSalesWeb.PageController"]
    assert names(result.phoenix.components) == ["EventSalesWeb.Admin.Components.StatCard"]
    assert names(result.oban.workers) == ["EventSales.Ingestion.Workers.ProcessWebhookWorker"]
  end

  defp names(modules), do: Enum.map(modules, & &1.name)

  defp temp_root do
    root =
      Path.join(System.tmp_dir!(), "project-index-scanner-#{System.unique_integer([:positive])}")

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
end
