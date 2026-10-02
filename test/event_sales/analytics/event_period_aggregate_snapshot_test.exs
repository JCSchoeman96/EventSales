defmodule EventSales.Analytics.EventPeriodAggregateSnapshotTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @bucket_start ~U[2026-05-18 08:00:00.000000Z]
  @bucket_end ~U[2026-05-18 09:00:00.000000Z]
  @refreshed_at ~U[2026-05-18 09:05:00.000000Z]

  @bucket_identity_index "analytics_event_period_aggregate_snapshots_identity_idx"
  @bucket_timezone_constraint "analytics_event_period_bucket_timezone_check"
  @bucket_bounds_constraint "analytics_event_period_bucket_bounds_check"
  @projection_state_constraint "analytics_event_period_projection_state_check"
  @semantic_version_constraint "analytics_event_period_semantic_version_check"
  @coverage_identity_constraint "analytics_event_period_coverage_identity_check"
  @primitive_constraints %{
    gross_ticket_quantity: "analytics_event_period_gross_quantity_check",
    gross_ticket_value: "analytics_event_period_gross_value_check",
    refund_ticket_quantity: "analytics_event_period_refund_quantity_check",
    refund_ticket_value: "analytics_event_period_refund_value_check"
  }

  setup do
    source_a = SalesHelpers.create_source_system!(%{name: "Period Source A"})
    source_b = SalesHelpers.create_source_system!(%{name: "Period Source B"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Period Event A",
        slug: unique_slug("period-a")
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Period Event B",
        slug: unique_slug("period-b")
      })

    %{event_a: event_a, event_b: event_b}
  end

  test "a current zero bucket is a persisted complete coverage row", %{event_a: event} do
    assert {:ok, snapshot} =
             create_snapshot(%{
               event_id: event.id,
               projection_state: :current,
               gross_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("0"),
               refund_ticket_quantity: 0,
               refund_ticket_value: Decimal.new("0")
             })

    assert snapshot.projection_state == :current
    assert snapshot.gross_ticket_quantity == 0
    assert snapshot.refund_ticket_quantity == 0
    assert Decimal.equal?(snapshot.gross_ticket_value, Decimal.new("0"))
    assert Decimal.equal?(snapshot.refund_ticket_value, Decimal.new("0"))
  end

  test "duplicate exact event currency bucket identity fails", %{event_a: event} do
    attrs = %{event_id: event.id}

    assert {:ok, _} = create_snapshot(attrs)
    assert {:error, _} = create_snapshot(attrs)
  end

  test "same bounds are allowed for another event or currency", %{
    event_a: event_a,
    event_b: event_b
  } do
    assert {:ok, _} =
             create_snapshot(%{event_id: event_a.id, currency: "ZAR"})

    assert {:ok, _} =
             create_snapshot(%{event_id: event_a.id, currency: "USD"})

    assert {:ok, _} =
             create_snapshot(%{event_id: event_b.id, currency: "ZAR"})
  end

  test "supported bucket kinds require their canonical timezone", %{event_a: event} do
    assert {:ok, _} =
             create_snapshot(%{
               event_id: event.id,
               bucket_kind: :utc_hour,
               bucket_timezone: "UTC"
             })

    assert {:ok, _} =
             create_snapshot(%{
               event_id: event.id,
               bucket_kind: :johannesburg_day,
               bucket_timezone: "Africa/Johannesburg",
               bucket_start_utc: ~U[2026-05-18 00:00:00.000000Z],
               bucket_end_utc: ~U[2026-05-18 22:00:00.000000Z]
             })
  end

  test "invalid bucket kind and timezone pairs fail", %{event_a: event} do
    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               bucket_kind: :utc_hour,
               bucket_timezone: "Africa/Johannesburg"
             })

    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               bucket_kind: :johannesburg_day,
               bucket_timezone: "UTC"
             })
  end

  test "equal or reversed bucket bounds fail", %{event_a: event} do
    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               bucket_start_utc: @bucket_start,
               bucket_end_utc: @bucket_start
             })

    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               bucket_start_utc: @bucket_end,
               bucket_end_utc: @bucket_start
             })
  end

  test "negative additive primitives, invalid state, and non-positive semantic version fail",
       %{event_a: event} do
    for {field, value} <- [
          gross_ticket_quantity: -1,
          gross_ticket_value: Decimal.new("-0.01"),
          refund_ticket_quantity: -1,
          refund_ticket_value: Decimal.new("-0.01")
        ] do
      assert {:error, _} = create_snapshot(Map.put(%{event_id: event.id}, field, value))
    end

    assert {:error, _} =
             create_snapshot(%{event_id: event.id, projection_state: :unknown})

    assert {:error, _} =
             create_snapshot(%{event_id: event.id, semantic_version: 0})
  end

  test "empty coverage identity fails through Ash", %{event_a: event} do
    assert {:error, _} =
             create_snapshot(%{event_id: event.id, coverage_identity: ""})
  end

  test "resource does not persist derived metrics or order count" do
    attributes =
      EventPeriodAggregateSnapshot
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    refute :net_ticket_quantity in attributes
    refute :net_ticket_value in attributes
    refute :average_ticket_value in attributes
    refute :absolute_delta in attributes
    refute :percentage_delta in attributes
    refute :recognised_order_count in attributes
  end

  test "resource is registered in the analytics domain" do
    assert EventPeriodAggregateSnapshot in Ash.Domain.Info.resources(Analytics)
  end

  test "postgres identity index rejects an exact duplicate", %{event_a: event} do
    assert {:ok, _} = create_snapshot(%{event_id: event.id})

    assert {:error, %Postgrex.Error{postgres: %{constraint: @bucket_identity_index}}} =
             insert_raw_snapshot(%{event_id: event.id})
  end

  test "postgres checks reject an invalid timezone pairing", %{event_a: event} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: @bucket_timezone_constraint}}} =
             insert_raw_snapshot(%{
               event_id: event.id,
               bucket_timezone: "Africa/Johannesburg"
             })
  end

  test "postgres checks reject non-increasing bounds", %{event_a: event} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: @bucket_bounds_constraint}}} =
             insert_raw_snapshot(%{
               event_id: event.id,
               bucket_end_utc: @bucket_start
             })
  end

  test "postgres checks reject invalid state and semantic version", %{event_a: event} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: @projection_state_constraint}}} =
             insert_raw_snapshot(%{event_id: event.id, projection_state: "missing"})

    assert {:error, %Postgrex.Error{postgres: %{constraint: @semantic_version_constraint}}} =
             insert_raw_snapshot(%{event_id: event.id, semantic_version: 0})
  end

  test "postgres check rejects an empty coverage identity", %{event_a: event} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: @coverage_identity_constraint}}} =
             insert_raw_snapshot(%{event_id: event.id, coverage_identity: ""})
  end

  test "postgres checks reject negative additive primitives", %{event_a: event} do
    for {field, constraint} <- @primitive_constraints do
      value =
        if field in [:gross_ticket_quantity, :refund_ticket_quantity],
          do: -1,
          else: Decimal.new("-0.01")

      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               insert_raw_snapshot(Map.put(%{event_id: event.id}, field, value))
    end
  end

  defp create_snapshot(attrs) do
    Ash.create(
      EventPeriodAggregateSnapshot,
      snapshot_attrs(attrs),
      action: :create_snapshot,
      domain: Analytics
    )
  end

  defp snapshot_attrs(attrs) do
    Map.merge(
      %{
        currency: "ZAR",
        bucket_kind: :utc_hour,
        bucket_start_utc: @bucket_start,
        bucket_end_utc: @bucket_end,
        bucket_timezone: "UTC",
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("100.00"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("0"),
        generation_id: Ecto.UUID.generate(),
        semantic_version: 1,
        coverage_identity: "m5_04_coverage_v1",
        projection_state: :current,
        refreshed_at: @refreshed_at,
        source_watermark_at: nil
      },
      Map.new(attrs)
    )
  end

  defp insert_raw_snapshot(attrs) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          currency: "ZAR",
          bucket_kind: "utc_hour",
          bucket_start_utc: @bucket_start,
          bucket_end_utc: @bucket_end,
          bucket_timezone: "UTC",
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          refund_ticket_quantity: 0,
          refund_ticket_value: Decimal.new("0"),
          generation_id: Ecto.UUID.generate(),
          semantic_version: 1,
          coverage_identity: "m5_04_coverage_v1",
          projection_state: "current",
          refreshed_at: @refreshed_at,
          source_watermark_at: nil,
          inserted_at: @refreshed_at,
          updated_at: @refreshed_at
        },
        attrs
      )

    Repo.query(
      """
      INSERT INTO analytics_event_period_aggregate_snapshots
      (id, event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc,
       bucket_timezone, gross_ticket_quantity, gross_ticket_value,
       refund_ticket_quantity, refund_ticket_value, generation_id,
       semantic_version, coverage_identity, projection_state, refreshed_at,
       source_watermark_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
              $15, $16, $17, $18, $19)
      """,
      [
        Ecto.UUID.dump!(row.id),
        Ecto.UUID.dump!(row.event_id),
        row.currency,
        row.bucket_kind,
        row.bucket_start_utc,
        row.bucket_end_utc,
        row.bucket_timezone,
        row.gross_ticket_quantity,
        row.gross_ticket_value,
        row.refund_ticket_quantity,
        row.refund_ticket_value,
        Ecto.UUID.dump!(row.generation_id),
        row.semantic_version,
        row.coverage_identity,
        row.projection_state,
        row.refreshed_at,
        row.source_watermark_at,
        row.inserted_at,
        row.updated_at
      ]
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
