defmodule EventSales.Analytics.PeriodCoverageMaterializer do
  @moduledoc false

  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Analytics.PeriodCoverageCurrencyResolver
  alias EventSales.Analytics.PeriodCoveragePlanner
  alias EventSales.Analytics.Workers.RefreshSnapshotWorker
  alias EventSales.Repo

  @period_snapshots "analytics_event_period_aggregate_snapshots"
  @coverage_identity "m5_04d:event_period_bucket_v1"
  @semantic_version 1
  @zero Decimal.new("0")

  @type result :: %{
          bucket_intents_created: non_neg_integer(),
          refresh_enqueued?: boolean(),
          currencies: [String.t()]
        }

  @doc """
  Inserts missing `refresh_pending` event-period bucket identities for one event.

  Does not mutate existing rows. Enqueues at most one event-scoped snapshot
  refresh when new intent rows were inserted.
  """
  @spec materialize(Ecto.UUID.t() | String.t(), DateTime.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def materialize(event_id, %DateTime{} = captured_now_utc, opts \\ [])
      when is_binary(event_id) do
    with {:ok, canonical_event_id} <- cast_uuid(event_id),
         {:ok, currencies} <-
           PeriodCoverageCurrencyResolver.currencies_for_event(canonical_event_id) do
      if currencies == [] do
        refresh_enqueued? =
          maybe_enqueue_snapshot_without_currency(canonical_event_id, opts)

        {:ok,
         %{
           bucket_intents_created: 0,
           refresh_enqueued?: refresh_enqueued?,
           currencies: []
         }}
      else
        bucket_specs = PeriodCoveragePlanner.required_bucket_specs(captured_now_utc)
        persist_and_enqueue(canonical_event_id, currencies, bucket_specs, opts)
      end
    end
  end

  defp persist_and_enqueue(event_id, currencies, bucket_specs, opts) do
    refresh_worker = Keyword.get(opts, :refresh_snapshot_worker, RefreshSnapshotWorker)

    case Repo.transaction(fn ->
           transaction_materialize(event_id, currencies, bucket_specs, refresh_worker, opts)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction_materialize(event_id, currencies, bucket_specs, refresh_worker, opts) do
    with :ok <- EventSnapshotRefreshFence.lock_events_in_transaction([event_id]),
         {inserted, _} <- insert_missing_intents(event_id, currencies, bucket_specs),
         :ok <- maybe_enqueue_refresh(inserted, event_id, refresh_worker, opts) do
      %{bucket_intents_created: inserted, refresh_enqueued?: inserted > 0, currencies: currencies}
    end
  end

  defp insert_missing_intents(event_id, currencies, bucket_specs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for currency <- currencies,
          spec <- bucket_specs do
        pending_row(event_id, currency, spec, now)
      end

    if rows == [] do
      {0, []}
    else
      Repo.insert_all(@period_snapshots, rows,
        on_conflict: :nothing,
        conflict_target: [
          :event_id,
          :currency,
          :bucket_kind,
          :bucket_start_utc,
          :bucket_end_utc
        ],
        returning: [:id]
      )
    end
  end

  defp pending_row(event_id, currency, spec, now) do
    %{
      id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      event_id: Ecto.UUID.dump!(event_id),
      currency: currency,
      bucket_kind: Atom.to_string(spec.bucket_kind),
      bucket_start_utc: spec.bucket_start_utc,
      bucket_end_utc: spec.bucket_end_utc,
      bucket_timezone: spec.bucket_timezone,
      gross_ticket_quantity: 0,
      gross_ticket_value: @zero,
      refund_ticket_quantity: 0,
      refund_ticket_value: @zero,
      generation_id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      semantic_version: @semantic_version,
      coverage_identity: @coverage_identity,
      projection_state: "refresh_pending",
      refreshed_at: now,
      source_watermark_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp maybe_enqueue_refresh(0, _event_id, _worker, _opts), do: :ok

  defp maybe_enqueue_refresh(inserted, event_id, worker, opts) when inserted > 0 do
    if Keyword.get(opts, :enqueue_refresh?, true) do
      case worker.enqueue_event(event_id, opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :ok
    end
  end

  defp maybe_enqueue_snapshot_without_currency(event_id, opts) do
    if Keyword.get(opts, :enqueue_snapshot_when_no_currency?, true) do
      worker = Keyword.get(opts, :refresh_snapshot_worker, RefreshSnapshotWorker)

      case worker.enqueue_event(event_id, opts) do
        :ok -> true
        {:error, _} -> false
      end
    else
      false
    end
  end

  defp cast_uuid(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_event_id}
    end
  end
end
