defmodule EventSales.Analytics.SourceFreshness do
  @moduledoc """
  Postgres-backed reader for event source-freshness classification.

  Component watermarks are persisted on
  `EventSales.Analytics.Resources.EventSourceFreshnessSnapshot`. This module
  derives the authoritative anchor on read and delegates age classification to
  `EventSales.Analytics.TimeRules`.
  """

  require Ash.Query
  import Ash.Expr

  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
  alias EventSales.Analytics.TimeRules

  @type classification :: :normal | :aging | :stale

  @type freshness_result :: %{
          classification: classification(),
          anchor_at: DateTime.t(),
          age_ms: non_neg_integer()
        }

  @doc """
  Returns source-freshness classification for one event.

  Pass `now` in `opts` for deterministic tests.
  """
  @spec for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, freshness_result()} | {:error, :missing_source_freshness_anchor | term()}
  def for_event(event_id, opts \\ []) when is_binary(event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, %EventSourceFreshnessSnapshot{} = snapshot} <- fetch_snapshot(event_id) do
      case source_freshness_anchor_at(snapshot) do
        %DateTime{} = anchor_at ->
          freshness = TimeRules.classify_source_freshness(anchor_at, now)

          {:ok,
           %{
             classification: freshness.classification,
             anchor_at: anchor_at,
             age_ms: div(freshness.age_microseconds, 1_000)
           }}

        nil ->
          {:error, :missing_source_freshness_anchor}
      end
    end
  end

  defp fetch_snapshot(event_id) do
    case EventSourceFreshnessSnapshot
         |> Ash.Query.filter(expr(event_id == ^event_id))
         |> Ash.read_one(domain: EventSales.Analytics) do
      {:ok, nil} -> {:error, :missing_source_freshness_anchor}
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_freshness_anchor_at(%EventSourceFreshnessSnapshot{} = snapshot) do
    snapshot
    |> Map.take([
      :order_source_watermark_at,
      :refund_source_watermark_at,
      :sync_source_observed_at
    ])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      datetimes -> Enum.max_by(datetimes, &DateTime.to_unix(&1, :microsecond))
    end
  end
end
