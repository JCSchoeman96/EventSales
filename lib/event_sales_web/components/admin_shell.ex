defmodule EventSalesWeb.Components.AdminShell do
  @moduledoc """
  Render-only admin shell for EventSales internal admin pages.
  """

  use EventSalesWeb, :html

  @nav_items [
    {"Dashboard", "/admin/dashboard", "Main", :prefix},
    {"Events", "/admin/events", "Sales", :prefix},
    {"Imports", "/admin/imports", "Ops", :exact},
    {"Catalog Sync", "/admin/catalog-sync", "Ops", :exact},
    {"Webhooks", "/admin/webhooks", "Ops", :exact},
    {"Sync", "/admin/sync", "Ops", :exact},
    {"Reconciliation", "/admin/reconciliation", "Ops", :exact},
    {"Mappings", "/admin/mappings", "Ops", :exact},
    {"Oban", "/admin/oban", "Tools", :exact},
    {"Health", "/health", "Status", :exact}
  ]

  attr :current_path, :string, required: true
  attr :page_title, :string, required: true
  attr :page_description, :string, default: nil
  attr :flash, :map, required: true
  slot :actions
  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :nav_items, @nav_items)

    ~H"""
    <div class="drawer lg:drawer-open min-h-screen bg-base-200">
      <input id="admin-shell-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar border-b border-base-300 bg-base-100 px-4 lg:px-6">
          <div class="flex-none lg:hidden">
            <label for="admin-shell-drawer" class="btn btn-square btn-ghost" aria-label="Open menu">
              <.icon name="hero-bars-3" class="size-5" />
            </label>
          </div>
          <div class="flex-1">
            <.link href={~p"/admin/dashboard"} class="btn btn-ghost px-2 text-lg font-semibold">
              EventSales
            </.link>
          </div>
          <div class="flex-none">
            <div class="flex items-center gap-2">
              <.link href={~p"/health"} class="btn btn-ghost btn-sm">Health</.link>
              <.link href={~p"/admin/logout"} method="delete" class="btn btn-ghost btn-sm">
                Sign out
              </.link>
            </div>
          </div>
        </header>

        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-7xl space-y-6">
            <Layouts.flash_group flash={@flash} />

            <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <div class="breadcrumbs text-sm">
                  <ul>
                    <li><.link href={~p"/admin/dashboard"}>Admin</.link></li>
                    <li>{@page_title}</li>
                  </ul>
                </div>
                <h1 class="mt-2 text-2xl font-semibold text-base-content">{@page_title}</h1>
                <p :if={@page_description} class="mt-1 text-sm text-base-content/70">
                  {@page_description}
                </p>
              </div>
              <div :if={@actions != []} class="flex flex-wrap gap-2">
                {render_slot(@actions)}
              </div>
            </div>

            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="admin-shell-drawer" aria-label="Close menu" class="drawer-overlay"></label>
        <aside class="min-h-full w-72 border-r border-base-300 bg-base-100">
          <div class="px-4 py-5">
            <.link href={~p"/admin/dashboard"} class="text-xl font-semibold text-base-content">
              EventSales
            </.link>
            <div class="mt-1 text-xs uppercase tracking-wide text-base-content/50">
              Internal Admin
            </div>
          </div>

          <nav class="px-3 pb-6" aria-label="Admin navigation">
            <div :for={group <- nav_groups(@nav_items)} class="mb-4">
              <div class="px-3 pb-1 text-xs font-semibold uppercase text-base-content/50">
                {group}
              </div>
              <ul class="menu gap-1">
                <li :for={item <- items_for_group(@nav_items, group)}>
                  <.link
                    href={nav_path(item)}
                    class={nav_class(item, @current_path)}
                    aria-current={if active?(item, @current_path), do: "page", else: false}
                  >
                    <span>{nav_label(item)}</span>
                    <span :if={active?(item, @current_path)} class="badge badge-primary badge-sm">
                      Current
                    </span>
                  </.link>
                </li>
              </ul>
            </div>
          </nav>
        </aside>
      </div>
    </div>
    """
  end

  defp nav_groups(items) do
    items
    |> Enum.map(fn {_label, _path, group, _match} -> group end)
    |> Enum.uniq()
  end

  defp items_for_group(items, group) do
    Enum.filter(items, fn {_label, _path, item_group, _match} -> item_group == group end)
  end

  defp nav_label({label, _path, _group, _match}), do: label
  defp nav_path({_label, path, _group, _match}), do: path

  defp nav_class(item, current_path) do
    [
      "justify-between",
      active?(item, current_path) && "active"
    ]
  end

  defp active?({_label, path, _group, :exact}, current_path), do: current_path == path

  defp active?({_label, path, _group, :prefix}, current_path),
    do: String.starts_with?(current_path, path)
end
