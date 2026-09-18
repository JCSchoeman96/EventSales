defmodule EventSales.Ingestion.HistoricalRefundOrderItemImpactCoordinatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.HistoricalRefundOrderItemImpactCoordinator
  alias EventSales.Repo

  @event_a "00000000-0000-0000-0000-00000000000a"
  @event_b "00000000-0000-0000-0000-00000000000b"

  test "compares captured Refund allocations in deterministic Refund order" do
    before = [snapshot("00000000-0000-0000-0000-000000000002", @event_a)]
    after_snapshots = [snapshot("00000000-0000-0000-0000-000000000002", @event_b)]

    assert [
             %{
               refund_id: "00000000-0000-0000-0000-000000000002",
               before_snapshot: _before,
               after_snapshot: _after,
               event_ids: [@event_a, @event_b]
             }
           ] = HistoricalRefundOrderItemImpactCoordinator.compare(before, after_snapshots)
  end

  test "does not report unchanged allocation" do
    snapshots = [snapshot("00000000-0000-0000-0000-000000000001", @event_a)]

    assert [] = HistoricalRefundOrderItemImpactCoordinator.compare(snapshots, snapshots)
  end

  test "fences the complete Event union before deterministic D3B calls" do
    changes = [
      impact_change("00000000-0000-0000-0000-000000000002", [@event_b]),
      impact_change("00000000-0000-0000-0000-000000000001", [@event_a, @event_b])
    ]

    test_pid = self()

    assert {:ok, :done} =
             Repo.transaction(fn ->
               assert :ok =
                        HistoricalRefundOrderItemImpactCoordinator.invalidate_changes(
                          changes,
                          historical_refund_coverage_invalidator: fn _before, _after, event_ids ->
                            send(test_pid, {:d3b, event_ids})
                            {:ok, %{}}
                          end
                        )

               :done
             end)

    assert_receive {:d3b, [@event_a, @event_b]}
    assert_receive {:d3b, [@event_b]}
  end

  defp snapshot(refund_id, event_id) do
    %{
      refund_truth: %{id: refund_id},
      refund_line_truth: [
        %{order_item_id: "00000000-0000-0000-0000-000000000010", binding_reason: nil}
      ],
      parent_order_evidence: nil,
      parent_order_item_evidence: [
        %{
          id: "00000000-0000-0000-0000-000000000010",
          event_id: event_id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      ]
    }
  end

  defp impact_change(refund_id, event_ids) do
    %{
      refund_id: refund_id,
      before_snapshot: %{},
      after_snapshot: %{},
      event_ids: event_ids
    }
  end
end
