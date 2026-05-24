defmodule EventSalesWeb.MishkaComponents do
  @moduledoc """
  Opt-in import of Mishka Chelekom components.
  Use only in component files that actively use `<.mishka_component>` calls.
  Do NOT add this to LiveView modules unless templates use Mishka tags directly.
  """

  defmacro __using__(_opts) do
    quote do
      import EventSalesWeb.Components.Alert
      import EventSalesWeb.Components.Badge
      import EventSalesWeb.Components.Divider
      import EventSalesWeb.Components.Dropdown
      import EventSalesWeb.Components.Indicator
      import EventSalesWeb.Components.Navbar
      import EventSalesWeb.Components.Pagination
      import EventSalesWeb.Components.Progress
      import EventSalesWeb.Components.Rating
      import EventSalesWeb.Components.Sidebar
      import EventSalesWeb.Components.Skeleton
      import EventSalesWeb.Components.Spinner
      import EventSalesWeb.Components.Tabs
      import EventSalesWeb.Components.Toast
      import EventSalesWeb.Components.Tooltip
    end
  end
end
