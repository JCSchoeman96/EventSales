defmodule EventSalesWeb.Components.AdminShellTest do
  use EventSalesWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EventSalesWeb.Components.AdminShell

  test "renders admin navigation links and marks the current section" do
    html =
      render_component(&AdminShell.shell/1,
        flash: %{},
        current_path: "/admin/dashboard",
        page_title: "Admin Dashboard",
        page_description: "Internal sales visibility",
        inner_block: [%{inner_block: fn _, _ -> "Dashboard body" end}]
      )

    assert html =~ "EventSales"
    assert html =~ "Admin Dashboard"
    assert html =~ "Internal sales visibility"
    assert html =~ "Dashboard body"
    assert html =~ ~s(href="/admin/dashboard")
    assert html =~ ~s(href="/admin/events")
    assert html =~ ~s(href="/admin/imports")
    assert html =~ ~s(href="/admin/webhooks")
    assert html =~ ~s(href="/admin/sync")
    assert html =~ ~s(href="/admin/reconciliation")
    assert html =~ ~s(href="/admin/catalog-sync")
    assert html =~ ~s(href="/admin/mappings")
    assert html =~ ~s(href="/admin/oban")
    assert html =~ ~s(href="/health")
    assert html =~ ~s(href="/admin/logout")
    assert html =~ ~s(data-method="delete")
    assert html =~ ~s(aria-current="page")
    refute html =~ ~s(href="/internal/mappings")
    refute html =~ ~s(href="/internal/ash-admin")
  end

  test "marks catalog sync as active when current path matches" do
    html =
      render_component(&AdminShell.shell/1,
        flash: %{},
        current_path: "/admin/catalog-sync",
        page_title: "Catalog Sync",
        page_description: "Tickera catalog sync",
        inner_block: [%{inner_block: fn _, _ -> "Catalog body" end}]
      )

    assert html =~ ~s(href="/admin/catalog-sync")
    assert html =~ ~s(aria-current="page")
    assert html =~ "Current"
  end

  test "does not render known PII strings" do
    html =
      render_component(&AdminShell.shell/1,
        flash: %{},
        current_path: "/admin/events",
        page_title: "Events",
        page_description: "Event summaries",
        inner_block: [%{inner_block: fn _, _ -> "Safe body" end}]
      )

    refute html =~ "private@example.test"
    refute html =~ "Private Customer"
    refute html =~ "customer_email"
  end

  test "source remains render-only and avoids backend dependencies" do
    source = File.read!("lib/event_sales_web/components/admin_shell.ex")

    for forbidden <- [
          "EventSales.Accounts",
          "EventSales.Accounts.Resources.Role",
          "EventSales.Accounts.Resources.User",
          "EventSales.Analytics.AdminDashboard",
          "EventSales.Repo",
          "EventSales.Sales.Resources.Order",
          "WooCommerce",
          "Tickera",
          "Ash."
        ] do
      refute source =~ forbidden
    end
  end
end
