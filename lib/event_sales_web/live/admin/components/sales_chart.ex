defmodule EventSalesWeb.Live.Admin.Components.SalesChart do
  @moduledoc """
  Chart.js area chart rendered via CDN script tag.
  Data flows server → data-* attrs → inline script.
  `phx-update="ignore"` prevents LiveView from wiping the canvas on patches.
  """

  use Phoenix.LiveComponent

  attr :id, :string, required: true
  attr :labels, :list, default: []
  attr :revenue, :list, default: []
  attr :tickets, :list, default: []

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :canvas_id, "sales-chart-#{assigns.id}")

    ~H"""
    <div>
      <div class="relative w-full" style="height: 260px;">
        <canvas
          id={@canvas_id}
          phx-update="ignore"
          data-labels={Jason.encode!(@labels)}
          data-revenue={Jason.encode!(@revenue)}
          data-tickets={Jason.encode!(@tickets)}
          class="h-full w-full"
        >
        </canvas>
      </div>

      <script>
        (function () {
          var canvasId = "<%= @canvas_id %>";

          function boot(canvas) {
            if (canvas._chart) { canvas._chart.destroy(); }

            var labels  = JSON.parse(canvas.dataset.labels  || "[]");
            var revenue = JSON.parse(canvas.dataset.revenue || "[]");
            var tickets = JSON.parse(canvas.dataset.tickets || "[]");

            canvas._chart = new Chart(canvas, {
              type: "line",
              data: {
                labels: labels,
                datasets: [
                  {
                    label: "Revenue (R)",
                    data: revenue,
                    borderColor: "#0ea5e9",
                    backgroundColor: "rgba(14,165,233,0.10)",
                    fill: true,
                    tension: 0.4,
                    pointRadius: 3,
                    pointHoverRadius: 6,
                    yAxisID: "yR"
                  },
                  {
                    label: "Tickets",
                    data: tickets,
                    borderColor: "#8b5cf6",
                    backgroundColor: "rgba(139,92,246,0.10)",
                    fill: true,
                    tension: 0.4,
                    pointRadius: 3,
                    pointHoverRadius: 6,
                    yAxisID: "yT"
                  }
                ]
              },
              options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { mode: "index", intersect: false },
                plugins: {
                  legend: { position: "top", labels: { boxWidth: 12, padding: 16 } }
                },
                scales: {
                  x: { grid: { color: "rgba(0,0,0,0.05)" } },
                  yR: {
                    position: "left",
                    ticks: {
                      callback: function (v) { return "R " + v.toLocaleString("en-ZA"); }
                    }
                  },
                  yT: {
                    position: "right",
                    grid: { drawOnChartArea: false }
                  }
                }
              }
            });
          }

          function waitForChartJs(canvas) {
            if (typeof Chart !== "undefined") {
              boot(canvas);
            } else {
              setTimeout(function () { waitForChartJs(canvas); }, 40);
            }
          }

          document.addEventListener("DOMContentLoaded", function () {
            var canvas = document.getElementById(canvasId);
            if (canvas) { waitForChartJs(canvas); }
          });

          (function () {
            var canvas = document.getElementById(canvasId);
            if (canvas && typeof Chart !== "undefined") { boot(canvas); }
          })();
        })();
      </script>
    </div>
    """
  end
end
