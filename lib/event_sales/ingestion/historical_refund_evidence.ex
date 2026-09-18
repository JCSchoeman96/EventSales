defmodule EventSales.Ingestion.HistoricalRefundEvidence do
  @moduledoc """
  Writes one historical Order's exact refund-reference checkpoint.

  Source HTTP and durable Sales refund synchronization happen before this
  module runs. This module only writes the bounded observation/reference proof
  inside the caller's existing checkpoint transaction.
  """

  require Ash.Query

  alias EventSales.Ingestion

  alias EventSales.Ingestion.Resources.{
    HistoricalOrderMembership,
    HistoricalRefundObservation,
    HistoricalRefundReference
  }

  alias EventSales.Sales
  alias EventSales.Sales.Resources.Refund

  @type evidence :: %{
          required(:reference_ids) => [pos_integer()],
          required(:observed_at) => DateTime.t(),
          required(:source_system_id) => Ecto.UUID.t(),
          required(:source_order_id) => pos_integer()
        }

  @spec persist(:manifest | :catchup, HistoricalOrderMembership.t(), evidence(), keyword()) ::
          {:ok, [term()]} | {:error, atom()}
  def persist(phase, membership, evidence, opts \\ [])

  def persist(phase, %HistoricalOrderMembership{} = membership, evidence, opts)
      when phase in [:manifest, :catchup] do
    with {:ok, observation, notifications} <- persist_observation(phase, membership, evidence),
         {:ok, reference_notifications} <-
           persist_references(observation, evidence, opts) do
      {:ok, notifications ++ reference_notifications}
    end
  end

  def persist(_phase, _membership, _evidence, _opts),
    do: {:error, :refund_reference_checkpoint_failed}

  defp persist_observation(:manifest, membership, evidence) do
    Ash.create(
      HistoricalRefundObservation,
      observation_attrs(membership, evidence),
      action: :resolve_manifest,
      domain: Ingestion,
      return_notifications?: true
    )
    |> normalize_observation_result()
  end

  defp persist_observation(:catchup, membership, evidence) do
    case observation_for_membership(membership.id) do
      {:ok, observation} ->
        if is_nil(observation) do
          {:error, :refund_reference_observation_missing}
        else
          update_catchup_observation(observation, evidence)
        end

      {:error, _reason} ->
        {:error, :refund_reference_observation_checkpoint_failed}
    end
  end

  defp update_catchup_observation(observation, evidence) do
    case Ash.update(
           observation,
           %{
             reference_count: length(evidence.reference_ids),
             observed_at: evidence.observed_at
           },
           action: :resolve_catchup,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:ok, updated} -> {:ok, updated, []}
      {:error, _reason} -> {:error, :refund_reference_observation_checkpoint_failed}
    end
  end

  defp normalize_observation_result({:ok, observation, notifications}),
    do: {:ok, observation, notifications}

  defp normalize_observation_result({:ok, observation}), do: {:ok, observation, []}

  defp normalize_observation_result({:error, _reason}),
    do: {:error, :refund_reference_observation_checkpoint_failed}

  defp observation_attrs(membership, evidence) do
    %{
      historical_order_membership_id: membership.id,
      reference_count: length(evidence.reference_ids),
      observed_at: evidence.observed_at
    }
  end

  defp observation_for_membership(membership_id) do
    HistoricalRefundObservation
    |> Ash.Query.filter(historical_order_membership_id == ^membership_id)
    |> Ash.read_one(domain: Ingestion)
  end

  defp persist_references(observation, evidence, opts) do
    with {:ok, existing} <- references_for_observation(observation.id),
         {:ok, notifications} <- ensure_present_references(observation, evidence, existing),
         {:ok, deletion_notifications} <-
           confirm_disappeared_references(existing, evidence, opts) do
      {:ok, notifications ++ deletion_notifications}
    end
  end

  defp references_for_observation(observation_id) do
    HistoricalRefundReference
    |> Ash.Query.filter(historical_refund_observation_id == ^observation_id)
    |> Ash.Query.sort(woo_refund_id: :asc)
    |> Ash.read(domain: Ingestion)
  end

  defp ensure_present_references(observation, evidence, existing) do
    existing_by_id = Map.new(existing, &{&1.woo_refund_id, &1})

    Enum.reduce_while(
      evidence.reference_ids,
      {:ok, []},
      &persist_reference(&1, &2, observation, evidence.observed_at, existing_by_id)
    )
  end

  defp persist_reference(
         refund_id,
         {:ok, notifications},
         observation,
         observed_at,
         existing_by_id
       ) do
    if match?(%{source_state: :absent_confirmed}, Map.get(existing_by_id, refund_id)) do
      {:halt, {:error, :voided_refund_reappeared}}
    else
      case observe_present_reference(observation, refund_id, observed_at) do
        {:ok, new_notifications} -> {:cont, {:ok, notifications ++ new_notifications}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp observe_present_reference(observation, refund_id, observed_at) do
    case Ash.create(
           HistoricalRefundReference,
           %{
             historical_refund_observation_id: observation.id,
             woo_refund_id: refund_id,
             last_observed_at: observed_at
           },
           action: :observe_present,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, _reference, notifications} -> {:ok, notifications}
      {:ok, _reference} -> {:ok, []}
      {:error, _reason} -> {:error, :refund_reference_checkpoint_failed}
    end
  end

  defp confirm_disappeared_references(existing, evidence, opts) do
    current_ids = MapSet.new(evidence.reference_ids)

    existing
    |> Enum.filter(&(&1.source_state == :present))
    |> Enum.reject(&MapSet.member?(current_ids, &1.woo_refund_id))
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, notifications} ->
      with :ok <- source_deletion_confirmed?(evidence, reference.woo_refund_id, opts),
           {:ok, _updated, new_notifications} <-
             Ash.update(
               reference,
               %{last_observed_at: evidence.observed_at},
               action: :confirm_absent,
               domain: Ingestion,
               return_notifications?: true
             ) do
        {:cont, {:ok, notifications ++ new_notifications}}
      else
        {:ok, _updated} -> {:cont, {:ok, notifications}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp source_deletion_confirmed?(evidence, woo_refund_id, _opts) do
    Refund
    |> Ash.Query.filter(
      source_system_id == ^evidence.source_system_id and
        woo_order_id == ^evidence.source_order_id and
        woo_refund_id == ^woo_refund_id
    )
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, [%Refund{source_state: :voided}]} -> :ok
      {:ok, _refunds} -> {:error, :refund_reference_deletion_unconfirmed}
      {:error, _reason} -> {:error, :refund_reference_deletion_unconfirmed}
    end
  end
end
