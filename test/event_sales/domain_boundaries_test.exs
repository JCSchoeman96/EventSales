defmodule EventSales.DomainBoundariesTest do
  use ExUnit.Case, async: true

  @business_domains [
    EventSales.Accounts,
    EventSales.Catalog,
    EventSales.Sales,
    EventSales.Ingestion,
    EventSales.Analytics,
    EventSales.Audit
  ]

  @forbidden_woocommerce_rest_patterns [
    "WooCommerceClient",
    "Req.",
    "Tesla.",
    "Finch.",
    "HTTPoison.",
    "/wp-json/wc/"
  ]

  test "business Ash domain modules compile and load" do
    for domain <- @business_domains do
      assert Code.ensure_loaded?(domain)
    end
  end

  test "business Ash domains are registered after the baseline domain" do
    configured_domains = Application.fetch_env!(:event_sales, :ash_domains)

    assert configured_domains == [
             EventSales.AshBaseline.Domain,
             EventSales.Accounts,
             EventSales.Catalog,
             EventSales.Sales,
             EventSales.Ingestion,
             EventSales.Analytics,
             EventSales.Audit
           ]
  end

  test "business Ash domains expose only resources owned by completed slices" do
    assert Ash.Domain.Info.resources(EventSales.Accounts) == [
             EventSales.Accounts.Resources.User,
             EventSales.Accounts.Resources.Role,
             EventSales.Accounts.Resources.UserRole,
             EventSales.Accounts.Resources.EventAccessGrant
           ]

    for domain <- @business_domains -- [EventSales.Accounts] do
      assert Ash.Domain.Info.resources(domain) == []
    end
  end

  test "web layer does not define Ash resources" do
    assert [] =
             implementation_files("lib/event_sales_web") |> files_containing("use Ash.Resource")
  end

  test "web layer and MappingResolver do not reference WooCommerce REST boundaries" do
    scan_paths =
      implementation_files("lib/event_sales_web") ++
        ["lib/event_sales/catalog/mapping_resolver.ex"]

    for pattern <- @forbidden_woocommerce_rest_patterns do
      assert [] = files_containing(scan_paths, pattern)
    end
  end

  defp implementation_files(path) do
    path
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp files_containing(paths, pattern) when is_list(paths) do
    paths
    |> Enum.filter(fn path ->
      path
      |> File.read!()
      |> String.contains?(pattern)
    end)
  end
end
