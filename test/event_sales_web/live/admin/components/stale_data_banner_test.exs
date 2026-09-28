defmodule EventSalesWeb.Live.Admin.Components.StaleDataBannerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EventSalesWeb.Live.Admin.Components.StaleDataBanner

  test "shows a warning while the read model is warming" do
    assert_warning(read_model(:warming), source_freshness(:normal))
  end

  test "shows a warning while the read model is degraded" do
    assert_warning(read_model(:degraded), source_freshness(:normal))
  end

  test "shows a warning for aging source freshness" do
    assert_warning(read_model(:ready), source_freshness(:aging))
  end

  test "shows a warning for stale source freshness" do
    assert_warning(read_model(:ready), source_freshness(:stale))
  end

  test "hides the warning when the read model and source are current" do
    html =
      render_component(&StaleDataBanner.banner/1,
        read_model: read_model(:ready),
        source_freshness: source_freshness(:normal)
      )

    refute html =~ ~s(role="alert")
  end

  test "missing source evidence does not create a fourth classification" do
    html =
      render_component(&StaleDataBanner.banner/1,
        read_model: read_model(:ready),
        source_freshness: %{
          result: {:error, :missing_source_freshness_anchor},
          counts: %{missing: 1}
        }
      )

    refute html =~ ~s(role="alert")
  end

  defp assert_warning(read_model, source_freshness) do
    html =
      render_component(&StaleDataBanner.banner/1,
        read_model: read_model,
        source_freshness: source_freshness
      )

    assert html =~ ~s(role="alert")
  end

  defp read_model(lifecycle) do
    %{lifecycle: lifecycle, generated_at: nil, rebuild_in_flight?: false}
  end

  defp source_freshness(classification) do
    %{
      result:
        {:ok,
         %{
           classification: classification,
           portfolio_anchor_at: ~U[2026-05-17 12:00:00Z]
         }},
      counts: %{normal: 1, aging: 0, stale: 0, missing: 0}
    }
  end
end
