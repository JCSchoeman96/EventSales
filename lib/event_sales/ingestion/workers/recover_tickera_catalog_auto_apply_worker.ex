defmodule EventSales.Ingestion.Workers.RecoverTickeraCatalogAutoApplyWorker do
  @moduledoc "Bounded same-job reconciliation for catalog auto-Apply decisions."

  use Oban.Worker, queue: :tickera_sync, max_attempts: 5

  import Ecto.Query

  alias EventSales.Ingestion.Resources.TickeraCatalogAutoApplyDecision
  alias EventSales.Repo

  @batch_size 100
  @terminal_attempt 20

  @impl Oban.Worker
  def perform(_job) do
    run_batch()
    :ok
  end

  def run_batch(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      ids =
        Repo.all(
          from decision in TickeraCatalogAutoApplyDecision,
            where:
              decision.enqueue_state in [:enqueued, :retryable_failure, :claimed] and
                (is_nil(decision.next_attempt_at) or decision.next_attempt_at <= ^now),
            order_by: [asc: decision.next_attempt_at, asc: decision.id],
            limit: @batch_size,
            lock: "FOR UPDATE SKIP LOCKED",
            select: decision.id
        )

      Enum.map(ids, &reconcile_decision(&1, now: now))
    end)
  end

  def reconcile_decision(decision_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    result =
      Repo.transaction(fn ->
        decision =
          Repo.one(
            from item in TickeraCatalogAutoApplyDecision,
              where: item.id == ^decision_id,
              lock: "FOR UPDATE"
          )

        case decision do
          nil -> Repo.rollback(:not_found)
          decision -> reconcile_locked(decision, now)
        end
      end)

    case result do
      {:ok, _value} ->
        Ash.get(TickeraCatalogAutoApplyDecision, decision_id, domain: EventSales.Ingestion)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_locked(%{apply_job_id: nil} = decision, _now),
    do: terminal(decision, "linked_job_missing")

  defp reconcile_locked(%{enqueue_state: :retryable_failure} = decision, now) do
    if due?(decision.next_attempt_at, now) do
      retry_same_job(decision)
    else
      :waiting
    end
  end

  defp reconcile_locked(decision, now) do
    case Repo.get(Oban.Job, decision.apply_job_id) do
      nil ->
        terminal(decision, "linked_job_missing")

      %{state: state} when state in ["available", "scheduled", "retryable", "executing"] ->
        :active

      %{state: "completed"} ->
        reconcile_completed(decision)

      %{state: state} when state in ["discarded", "cancelled"] ->
        schedule_retry(decision, now)

      _job ->
        terminal(decision, "linked_job_state_unknown")
    end
  end

  defp reconcile_completed(decision) do
    status =
      Repo.one(
        from run in "ingestion_tickera_catalog_sync_runs",
          where: run.id == type(^decision.catalog_sync_run_id, :binary_id),
          select: run.status
      )

    if status == "applied" do
      update_decision(decision, apply_audit_state: :completed, completed_at: DateTime.utc_now())
    else
      terminal(decision, "completed_job_run_inconsistent")
    end
  end

  defp schedule_retry(%{enqueue_attempts: attempts} = decision, _now)
       when attempts >= @terminal_attempt,
       do: terminal(decision, "enqueue_attempts_exhausted")

  defp schedule_retry(decision, now) do
    run_status =
      Repo.one(
        from run in "ingestion_tickera_catalog_sync_runs",
          where: run.id == type(^decision.catalog_sync_run_id, :binary_id),
          select: run.status
      )

    cond do
      run_status in ["applied", "applying", "failed", "cancelled"] ->
        terminal(decision, "run_state_prevents_retry")

      decision.apply_audit_state in [:completed, :claimed, :failed] ->
        terminal(decision, "apply_audit_prevents_retry")

      true ->
        next_attempt = decision.enqueue_attempts + 1
        delay = min(trunc(30 * :math.pow(2, next_attempt - 1)), 1_800)

        update_decision(decision,
          enqueue_state: :retryable_failure,
          enqueue_attempts: next_attempt,
          next_attempt_at: DateTime.add(now, delay, :second)
        )
    end
  end

  defp retry_same_job(decision) do
    job = Repo.get(Oban.Job, decision.apply_job_id)

    if (job && job.state in ["discarded", "cancelled"]) and
         decision.enqueue_attempts <= @terminal_attempt do
      case Oban.retry_job(job.id) do
        :ok ->
          update_decision(decision, enqueue_state: :enqueued, next_attempt_at: nil)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      terminal(decision, "linked_job_not_retryable")
    end
  end

  defp terminal(decision, reason) do
    reasons = (decision.reason_codes ++ [reason]) |> Enum.uniq() |> Enum.take(32)

    update_decision(decision,
      enqueue_state: :terminal_failure,
      next_attempt_at: nil,
      reason_codes: reasons
    )
  end

  defp update_decision(decision, attrs) do
    {1, _rows} =
      Repo.update_all(
        from(item in TickeraCatalogAutoApplyDecision, where: item.id == ^decision.id),
        set: Keyword.put(attrs, :updated_at, DateTime.utc_now())
      )

    :updated
  end

  defp due?(nil, _now), do: false
  defp due?(due_at, now), do: DateTime.compare(due_at, now) in [:lt, :eq]
end
