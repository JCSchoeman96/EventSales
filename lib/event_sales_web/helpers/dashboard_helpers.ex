defmodule EventSalesWeb.DashboardHelpers do
  @moduledoc """
  Pure view-layer helpers for admin dashboard components.
  No Ash, no DB, no Oban calls. Pattern-match on known data shapes only.
  """

  # --- Order/ticket status → daisyUI badge class ---

  def status_color("completed"), do: "badge-success"
  def status_color("processing"), do: "badge-success"
  def status_color("pending"), do: "badge-warning"
  def status_color("on-hold"), do: "badge-warning"
  def status_color("refunded"), do: "badge-error"
  def status_color("cancelled"), do: "badge-error"
  def status_color("failed"), do: "badge-error"
  def status_color(_), do: "badge-info"

  # --- Capacity fill % → daisyUI progress class ---

  def capacity_color(pct) when pct > 85, do: "progress-error"
  def capacity_color(pct) when pct > 60, do: "progress-warning"
  def capacity_color(_), do: "progress-success"

  # --- Sync health → daisyUI badge class ---

  def sync_color(:ok), do: "badge-success"
  def sync_color(:stale), do: "badge-warning"
  def sync_color(:error), do: "badge-error"
  def sync_color(_), do: "badge-info"

  # --- Tickets sold % (safe division) ---
  # Expects %{tickets_sold: integer, capacity: integer}

  def sold_pct(%{tickets_sold: sold, capacity: cap}) when is_integer(cap) and cap > 0,
    do: round(sold / cap * 100)

  def sold_pct(_), do: 0

  # --- ZAR currency formatting (cents input) ---

  def format_zar(nil), do: "R 0.00"

  def format_zar(cents) when is_integer(cents) do
    rands = cents / 100
    "R #{:erlang.float_to_binary(rands, decimals: 2)}"
  end

  def format_zar(%Decimal{} = d) do
    d |> Decimal.to_float() |> round() |> format_zar()
  end

  # --- Date formatting ---

  def format_date(nil), do: "—"

  def format_date(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%d %b %Y, %H:%M")

  def format_date(%Date{} = d),
    do: Calendar.strftime(d, "%d %b %Y")

  # --- Relative time ---

  def relative_time(nil), do: "—"

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      true -> format_date(dt)
    end
  end

  # --- Delta display (revenue/ticket change vs previous period) ---

  def delta_label(nil), do: ""
  def delta_label(0), do: "—"
  def delta_label(d) when d > 0, do: "↑ #{d}"
  def delta_label(d), do: "↓ #{abs(d)}"

  def delta_class(nil), do: "text-zinc-400"
  def delta_class(0), do: "text-zinc-400"
  def delta_class(d) when d > 0, do: "text-success"
  def delta_class(_), do: "text-error"
end
