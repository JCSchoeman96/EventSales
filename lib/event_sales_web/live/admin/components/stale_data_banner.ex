defmodule EventSalesWeb.Live.Admin.Components.StaleDataBanner do
  @moduledoc """
  Presentational banner for read-model health and source freshness.
  """

  use Phoenix.Component

  attr :read_model, :map, required: true
  attr :source_freshness, :map, required: true

  def banner(assigns) do
    source_classification =
      case assigns.source_freshness[:result] do
        {:ok, %{classification: classification}} when classification in [:aging, :stale] ->
          classification

        _ ->
          nil
      end

    assigns = assign(assigns, :source_classification, source_classification)

    ~H"""
    <div
      :if={
        @read_model[:lifecycle] in [:warming, :degraded] or @source_classification in [:aging, :stale]
      }
      role="alert"
      class="alert alert-warning mb-6 shadow-sm"
    >
      <span :if={@read_model[:lifecycle] in [:warming, :degraded]}>
        Dashboard data is {@read_model[:lifecycle]}.
      </span>
      <span :if={@source_classification in [:aging, :stale]}>
        Source data is {@source_classification}.
      </span>
    </div>
    """
  end
end
