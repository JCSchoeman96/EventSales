defmodule EventSales.Ingestion.WebhookReplay do
  @moduledoc """
  Admin replay workflow for failed webhook events.

  This module queues existing failed `WebhookEvent` records for async
  processing. It never calls the processor directly and never revalidates
  intake-time replay guards.
  """

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Telemetry

  @type replay_result ::
          {:ok, WebhookEvent.t()}
          | {:error, :forbidden | :not_found | :not_failed | :enqueue_failed | term()}

  @doc """
  Queues a failed webhook event for replay.
  """
  @spec replay_failed(Ecto.UUID.t(), keyword()) :: replay_result()
  def replay_failed(webhook_event_id, opts \\ [])

  def replay_failed(webhook_event_id, opts) when is_binary(webhook_event_id) do
    with :ok <- authorize(opts),
         {:ok, %WebhookEvent{} = event} <- fetch_event(webhook_event_id),
         :ok <- require_failed(event),
         {:ok, replayed} <- queue_event(event),
         :ok <- enqueue_event(replayed, event) do
      audit_replay(replayed, event, :queued, nil, opts)
      {:ok, replayed}
    else
      {:ok, nil} ->
        {:error, :not_found}

      {:error, :enqueue_failed, %WebhookEvent{} = replayed, %WebhookEvent{} = original} ->
        audit_replay(replayed, original, :rejected, :enqueue_failed, opts)
        {:error, :enqueue_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def replay_failed(_webhook_event_id, _opts), do: {:error, :not_found}

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp fetch_event(webhook_event_id) do
    Ash.get(WebhookEvent, webhook_event_id, domain: Ingestion)
  end

  defp require_failed(%WebhookEvent{status: :failed}), do: :ok
  defp require_failed(%WebhookEvent{}), do: {:error, :not_failed}

  defp queue_event(%WebhookEvent{} = event) do
    Ash.update(
      event,
      %{
        failed_at: nil,
        error_message: nil,
        ignore_reason: nil,
        processed_at: nil,
        processing_started_at: nil
      },
      action: :queue_for_replay,
      domain: Ingestion
    )
  end

  defp enqueue_event(%WebhookEvent{} = replayed, %WebhookEvent{} = original) do
    case enqueue_module().enqueue_processing_once(replayed) do
      :ok -> :ok
      {:error, _reason} -> {:error, :enqueue_failed, replayed, original}
    end
  end

  defp audit_replay(%WebhookEvent{} = replayed, %WebhookEvent{} = original, result, reason, opts) do
    attrs = %{
      actor_type: :user,
      actor_user_id: opts |> Keyword.fetch!(:actor) |> Map.get(:id),
      actor_role: :admin,
      source: :admin,
      subject_type: "webhook_event",
      subject_id: replayed.id,
      metadata: safe_metadata(original, result, reason),
      ip: Keyword.get(opts, :ip),
      user_agent: Keyword.get(opts, :user_agent)
    }

    case audit_logger().webhook_replay_requested(attrs) do
      {:ok, _audit_log} ->
        :ok

      {:error, audit_reason} ->
        if result == :queued do
          emit_audit_failed(replayed, audit_reason)
        end

        {:error, audit_reason}
    end
  end

  defp safe_metadata(%WebhookEvent{} = event, result, reason) do
    %{
      webhook_event_id: event.id,
      delivery_id: event.delivery_id,
      topic: event.topic,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      previous_status: to_string(event.status),
      accepted_via: to_string(event.accepted_via),
      result: to_string(result),
      reason: reason && to_string(reason)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp emit_audit_failed(%WebhookEvent{} = event, reason) do
    Telemetry.emit(Telemetry.webhook_replay_audit_failed(), %{count: 1}, %{
      webhook_event_id: event.id,
      reason: reason
    })
  end

  defp enqueue_module do
    Application.get_env(
      :event_sales,
      :webhook_replay_enqueue,
      EventSales.Ingestion.WebhookEnqueue
    )
  end

  defp audit_logger do
    Application.get_env(:event_sales, :webhook_replay_audit_logger, EventSales.Audit.Logger)
  end
end
