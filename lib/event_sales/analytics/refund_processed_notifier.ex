defmodule EventSales.Analytics.RefundProcessedNotifier do
  @moduledoc """
  Advances event-scoped refund source freshness after a durable refund apply.

  This module runs after `RefundUpserter` commits. It resolves affected events
  from the refund's bound order and mapped ticket items. Projection failures
  are reported through bounded telemetry and do not affect the committed
  refund write.
  """

  require Ash.Query

  alias EventSales.Analytics.SourceFreshness
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{OrderItem, Refund}
  alias EventSales.Telemetry

  @doc "Advances refund source freshness for an applied durable refund fact."
  @spec notify_refund_applied(Refund.t(), keyword()) :: :ok
  def notify_refund_applied(refund, opts \\ [])

  def notify_refund_applied(
        %Refund{
          source_state: :active,
          source_created_at: %DateTime{} = source_created_at,
          order_id: order_id
        },
        opts
      )
      when is_binary(order_id) do
    case affected_event_ids(order_id) do
      {:ok, event_ids} ->
        Enum.each(event_ids, &advance_refund(&1, source_created_at, opts))

      {:error, _reason} ->
        emit_failure(:event_resolution)
    end

    :ok
  rescue
    _exception ->
      emit_failure(:event_resolution)
      :ok
  catch
    _kind, _reason ->
      emit_failure(:event_resolution)
      :ok
  end

  def notify_refund_applied(%Refund{}, _opts), do: :ok

  defp affected_event_ids(order_id) do
    OrderItem
    |> Ash.Query.filter(
      order_id == ^order_id and
        mapping_status == :mapped and
        item_kind == :ticket and
        not is_nil(event_id)
    )
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, rows} ->
        event_ids =
          rows
          |> Enum.map(& &1.event_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:ok, event_ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance_refund(event_id, source_created_at, opts) do
    source_freshness = Keyword.get(opts, :source_freshness, SourceFreshness)

    case source_freshness.advance_refund(event_id, source_created_at) do
      :ok ->
        :ok

      _failure ->
        emit_failure(:projection_write)
    end
  rescue
    _exception ->
      emit_failure(:projection_write)
  catch
    _kind, _reason ->
      emit_failure(:projection_write)
  end

  defp emit_failure(stage) do
    Telemetry.emit(Telemetry.source_freshness_advance_failed(), %{count: 1}, %{
      component: :refund,
      source: :refund_sync,
      stage: stage
    })
  end
end
