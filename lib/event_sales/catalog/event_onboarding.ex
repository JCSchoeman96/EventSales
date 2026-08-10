defmodule EventSales.Catalog.EventOnboarding do
  @moduledoc """
  Small durable helpers for the Event analytics onboarding state machine.

  The helper deliberately uses the existing Ash transitions. It never writes the
  onboarding state attribute directly and treats an already-unverified Event as an
  idempotent no-op.
  """

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Repo

  @event_lock_query "SELECT id FROM catalog_events WHERE id = $1 FOR UPDATE"

  @spec invalidate_if_pending(Ecto.UUID.t()) ::
          :ok | {:error, :event_onboarding_invalidation_failed}
  def invalidate_if_pending(event_id) when is_binary(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{analytics_onboarding_state: :unverified}} ->
        :ok

      {:ok, %Event{analytics_onboarding_state: :backfill_pending} = event} ->
        case Ash.update(event, %{},
               action: :invalidate_onboarding,
               domain: Catalog,
               context: %{warn_on_transaction_hooks?: false},
               return_notifications?: true
             ) do
          {:ok, %Event{}} -> :ok
          {:ok, %Event{}, _notifications} -> :ok
          _other -> {:error, :event_onboarding_invalidation_failed}
        end

      _other ->
        {:error, :event_onboarding_invalidation_failed}
    end
  end

  def invalidate_if_pending(_event_id),
    do: {:error, :event_onboarding_invalidation_failed}

  @spec invalidate_many(Enumerable.t()) :: :ok | {:error, :event_onboarding_invalidation_failed}
  def invalidate_many(event_ids) do
    event_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn event_id, :ok ->
      case invalidate_if_pending(event_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :event_onboarding_invalidation_failed}}
      end
    end)
  end

  @spec lock_events(Enumerable.t()) :: :ok | {:error, :event_onboarding_invalidation_failed}
  def lock_events(event_ids) do
    event_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn event_id, :ok ->
      case lock_event(event_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :event_onboarding_invalidation_failed}}
      end
    end)
  end

  defp lock_event(event_id) do
    with {:ok, cast_id} <- Ecto.UUID.cast(event_id),
         {:ok, %{num_rows: 1}} <-
           Repo.query(@event_lock_query, [Ecto.UUID.dump!(cast_id)]) do
      :ok
    else
      _other -> {:error, :event_onboarding_invalidation_failed}
    end
  end
end
