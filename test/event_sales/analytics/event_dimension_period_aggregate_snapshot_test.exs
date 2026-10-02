defmodule EventSales.Analytics.EventDimensionPeriodAggregateSnapshotTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.EventDimensionPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @bucket_start ~U[2026-05-18 08:00:00.000000Z]
  @bucket_end ~U[2026-05-18 09:00:00.000000Z]
  @refreshed_at ~U[2026-05-18 09:05:00.000000Z]

  @grain_constraint "analytics_dim_period_grain_shape_check"
  @ticket_identity_index "analytics_dim_period_ticket_type_uidx"
  @product_identity_index "analytics_dim_period_source_product_uidx"
  @primitive_constraints %{
    gross_ticket_quantity: "analytics_dim_period_gross_quantity_check",
    gross_ticket_value: "analytics_dim_period_gross_value_check",
    refund_ticket_quantity: "analytics_dim_period_refund_quantity_check",
    refund_ticket_value: "analytics_dim_period_refund_value_check"
  }
  @woo_constraints %{
    woo_product_id: "analytics_dim_period_woo_product_id_check",
    woo_variation_id: "analytics_dim_period_woo_variation_id_check"
  }

  setup do
    source_a = SalesHelpers.create_source_system!(%{name: "Dimension Period Source A"})
    source_b = SalesHelpers.create_source_system!(%{name: "Dimension Period Source B"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Dimension Period Event A",
        slug: unique_slug("dim-period-a")
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Dimension Period Event B",
        slug: unique_slug("dim-period-b")
      })

    same_source_event =
      SalesHelpers.create_event!(source_a, %{
        name: "Dimension Period Same Source Event",
        slug: unique_slug("dim-period-same-source")
      })

    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "GA"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Other GA"})

    inactive_ticket =
      SalesHelpers.create_ticket_type!(event_a, %{name: "Inactive", active: false})

    %{
      source_a: source_a,
      source_b: source_b,
      event_a: event_a,
      event_b: event_b,
      same_source_event: same_source_event,
      ticket_a: ticket_a,
      ticket_b: ticket_b,
      inactive_ticket: inactive_ticket
    }
  end

  test "creates all three normalized grains", %{
    event_a: event,
    source_a: source,
    ticket_a: ticket
  } do
    assert {:ok, ticket_row} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :ticket_type,
               ticket_type_id: ticket.id
             })

    assert ticket_row.dimension_kind == :ticket_type

    assert {:ok, product_row} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :source_product,
               source_system_id: source.id,
               woo_product_id: 10_001
             })

    assert product_row.dimension_kind == :source_product

    assert {:ok, variation_row} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :source_variation,
               source_system_id: source.id,
               woo_product_id: 10_002,
               woo_variation_id: 20_002
             })

    assert variation_row.dimension_kind == :source_variation
  end

  test "rejects missing and mixed grain identities", %{
    event_a: event,
    source_a: source,
    ticket_a: ticket
  } do
    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :ticket_type
             })

    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :ticket_type,
               ticket_type_id: ticket.id,
               source_system_id: source.id
             })

    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :source_product,
               source_system_id: source.id,
               woo_product_id: 10_003,
               woo_variation_id: 20_003
             })
  end

  test "a duplicate canonical grain in one bucket fails", %{
    event_a: event,
    ticket_a: ticket
  } do
    attrs = %{
      event_id: event.id,
      dimension_kind: :ticket_type,
      ticket_type_id: ticket.id
    }

    assert {:ok, _} = create_snapshot(attrs)
    assert {:error, _} = create_snapshot(attrs)
  end

  test "a grain may exist in another bucket and currency", %{
    event_a: event,
    ticket_a: ticket
  } do
    attrs = %{
      event_id: event.id,
      dimension_kind: :ticket_type,
      ticket_type_id: ticket.id
    }

    assert {:ok, _} = create_snapshot(attrs)

    assert {:ok, _} =
             create_snapshot(
               Map.merge(attrs, %{
                 bucket_start_utc: ~U[2026-05-18 09:00:00.000000Z],
                 bucket_end_utc: ~U[2026-05-18 10:00:00.000000Z]
               })
             )

    assert {:ok, _} = create_snapshot(Map.put(attrs, :currency, "USD"))
  end

  test "same source product identity may belong to another matching event/source pair", %{
    event_a: event_a,
    event_b: event_b,
    same_source_event: same_source_event,
    source_a: source_a,
    source_b: source_b
  } do
    for {event, source} <- [
          {event_a, source_a},
          {event_b, source_b},
          {same_source_event, source_a}
        ] do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 source_system_id: source.id,
                 woo_product_id: 71_001
               })
    end
  end

  test "ticket type must belong to the event", %{event_a: event, ticket_b: ticket} do
    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :ticket_type,
               ticket_type_id: ticket.id
             })
  end

  test "source system must match the event", %{event_a: event, source_b: source} do
    assert {:error, _} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :source_product,
               source_system_id: source.id,
               woo_product_id: 71_002
             })
  end

  test "inactive ticket type remains a valid historical identity", %{
    event_a: event,
    inactive_ticket: ticket
  } do
    assert {:ok, snapshot} =
             create_snapshot(%{
               event_id: event.id,
               dimension_kind: :ticket_type,
               ticket_type_id: ticket.id
             })

    assert snapshot.ticket_type_id == ticket.id
  end

  test "negative additive primitives fail", %{event_a: event, ticket_a: ticket} do
    for {field, value} <- [
          gross_ticket_quantity: -1,
          gross_ticket_value: Decimal.new("-0.01"),
          refund_ticket_quantity: -1,
          refund_ticket_value: Decimal.new("-0.01")
        ] do
      assert {:error, _} =
               create_snapshot(
                 Map.put(
                   %{
                     event_id: event.id,
                     dimension_kind: :ticket_type,
                     ticket_type_id: ticket.id
                   },
                   field,
                   value
                 )
               )
    end
  end

  test "does not persist net, average, or order-count values" do
    attributes =
      EventDimensionPeriodAggregateSnapshot
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    refute :net_ticket_quantity in attributes
    refute :net_ticket_value in attributes
    refute :average_ticket_value in attributes
    refute :recognised_order_count in attributes
  end

  test "resource is registered in the analytics domain" do
    assert EventDimensionPeriodAggregateSnapshot in Ash.Domain.Info.resources(Analytics)
  end

  test "postgres grain check rejects mixed identities", %{
    event_a: event,
    ticket_a: ticket
  } do
    assert {:error, %Postgrex.Error{postgres: %{constraint: @grain_constraint}}} =
             insert_raw_snapshot(%{
               event_id: event.id,
               dimension_kind: "ticket_type",
               ticket_type_id: ticket.id,
               woo_product_id: 71_003
             })
  end

  test "postgres partial unique index includes fixed bucket identity", %{
    event_a: event,
    ticket_a: ticket
  } do
    attrs = %{
      event_id: event.id,
      dimension_kind: :ticket_type,
      ticket_type_id: ticket.id
    }

    assert {:ok, _} = create_snapshot(attrs)

    assert {:error, %Postgrex.Error{postgres: %{constraint: @ticket_identity_index}}} =
             insert_raw_snapshot(%{
               event_id: event.id,
               dimension_kind: "ticket_type",
               ticket_type_id: ticket.id
             })
  end

  test "postgres partial product index enforces source product identity", %{
    event_a: event,
    source_a: source
  } do
    attrs = %{
      event_id: event.id,
      dimension_kind: :source_product,
      source_system_id: source.id,
      woo_product_id: 71_004
    }

    assert {:ok, _} = create_snapshot(attrs)

    assert {:error, %Postgrex.Error{postgres: %{constraint: @product_identity_index}}} =
             insert_raw_snapshot(%{
               event_id: event.id,
               dimension_kind: "source_product",
               source_system_id: source.id,
               woo_product_id: 71_004
             })
  end

  test "postgres partial variation index enforces source variation identity", %{
    event_a: event,
    source_a: source
  } do
    attrs = %{
      event_id: event.id,
      dimension_kind: :source_variation,
      source_system_id: source.id,
      woo_product_id: 71_006,
      woo_variation_id: 81_006
    }

    assert {:ok, _} = create_snapshot(attrs)

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "analytics_dim_period_source_variation_uidx"}
            }} =
             insert_raw_snapshot(Map.put(attrs, :dimension_kind, "source_variation"))
  end

  test "postgres checks reject negative primitives and non-positive Woo IDs", %{
    event_a: event,
    source_a: source
  } do
    for {field, constraint} <- @primitive_constraints do
      value =
        if field in [:gross_ticket_quantity, :refund_ticket_quantity],
          do: -1,
          else: Decimal.new("-0.01")

      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               insert_raw_snapshot(
                 Map.put(
                   %{
                     event_id: event.id,
                     dimension_kind: "source_product",
                     source_system_id: source.id,
                     woo_product_id: 71_005
                   },
                   field,
                   value
                 )
               )
    end

    for {field, constraint} <- @woo_constraints do
      dimension_kind =
        if field == :woo_variation_id, do: "source_variation", else: "source_product"

      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               insert_raw_snapshot(
                 Map.put(
                   %{
                     event_id: event.id,
                     dimension_kind: dimension_kind,
                     source_system_id: source.id,
                     woo_product_id: 71_005
                   },
                   field,
                   0
                 )
               )
    end
  end

  defp create_snapshot(attrs) do
    Ash.create(
      EventDimensionPeriodAggregateSnapshot,
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
          dimension_kind: "ticket_type",
          ticket_type_id: nil,
          source_system_id: nil,
          woo_product_id: nil,
          woo_variation_id: nil,
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
      INSERT INTO analytics_event_dimension_period_aggregate_snapshots
      (id, event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc,
       bucket_timezone, dimension_kind, ticket_type_id, source_system_id,
       woo_product_id, woo_variation_id, gross_ticket_quantity, gross_ticket_value,
       refund_ticket_quantity, refund_ticket_value, generation_id, semantic_version,
       coverage_identity, projection_state, refreshed_at, source_watermark_at,
       inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
              $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24)
      """,
      [
        Ecto.UUID.dump!(row.id),
        Ecto.UUID.dump!(row.event_id),
        row.currency,
        row.bucket_kind,
        row.bucket_start_utc,
        row.bucket_end_utc,
        row.bucket_timezone,
        row.dimension_kind,
        dump_optional_uuid(row.ticket_type_id),
        dump_optional_uuid(row.source_system_id),
        row.woo_product_id,
        row.woo_variation_id,
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

  defp dump_optional_uuid(nil), do: nil
  defp dump_optional_uuid(id), do: Ecto.UUID.dump!(id)

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
