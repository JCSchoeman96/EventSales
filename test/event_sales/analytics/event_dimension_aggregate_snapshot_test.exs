defmodule EventSales.Analytics.EventDimensionAggregateSnapshotTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.EventDimensionAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @refreshed_at ~U[2026-05-18 08:00:00.000000Z]
  @grain_shape_constraint "analytics_event_dim_agg_snapshots_grain_shape_check"
  @source_product_unique_index "analytics_event_dim_agg_snapshots_unique_source_product_idx"
  @refund_quantity_constraint "analytics_event_dim_agg_snapshots_refund_ticket_quantity_check"
  @refund_value_constraint "analytics_event_dim_agg_snapshots_refund_ticket_value_check"

  setup do
    source_a = SalesHelpers.create_source_system!(%{name: "Dimension Source A"})
    source_b = SalesHelpers.create_source_system!(%{name: "Dimension Source B"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Dimension Event A",
        slug: unique_slug("dim-a")
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Dimension Event B",
        slug: unique_slug("dim-b")
      })

    other_event =
      SalesHelpers.create_event!(source_a, %{
        name: "Other Dimension Event",
        slug: unique_slug("dim-other")
      })

    ticket = SalesHelpers.create_ticket_type!(event_a, %{name: "GA"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other GA"})

    inactive_ticket =
      SalesHelpers.create_ticket_type!(event_a, %{name: "Inactive", active: false})

    %{
      source_a: source_a,
      source_b: source_b,
      event_a: event_a,
      event_b: event_b,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket,
      inactive_ticket: inactive_ticket
    }
  end

  describe "valid grains" do
    test "ticket_type creates", %{event_a: event, ticket: ticket} do
      snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :ticket_type,
          ticket_type_id: ticket.id
        })

      assert snapshot.dimension_kind == :ticket_type
      assert snapshot.ticket_type_id == ticket.id
      assert is_nil(snapshot.source_system_id)
      assert is_nil(snapshot.woo_product_id)
      assert is_nil(snapshot.woo_variation_id)
    end

    test "source_product creates", %{event_a: event, source_a: source} do
      snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :source_product,
          source_system_id: source.id,
          woo_product_id: 10_001
        })

      assert snapshot.dimension_kind == :source_product
      assert snapshot.source_system_id == source.id
      assert snapshot.woo_product_id == 10_001
      assert is_nil(snapshot.ticket_type_id)
      assert is_nil(snapshot.woo_variation_id)
    end

    test "source_variation creates", %{event_a: event, source_a: source} do
      snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :source_variation,
          source_system_id: source.id,
          woo_product_id: 10_002,
          woo_variation_id: 20_002
        })

      assert snapshot.dimension_kind == :source_variation
      assert snapshot.woo_variation_id == 20_002
    end

    test "zero gross metrics are allowed", %{event_a: event, ticket: ticket} do
      snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :ticket_type,
          ticket_type_id: ticket.id,
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0")
        })

      assert snapshot.gross_ticket_quantity == 0
      assert Decimal.equal?(snapshot.gross_ticket_value, Decimal.new("0"))
    end

    test "refund fields default to zero when omitted", %{event_a: event, ticket: ticket} do
      snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :ticket_type,
          ticket_type_id: ticket.id
        })

      assert snapshot.refund_ticket_quantity == 0
      assert Decimal.equal?(snapshot.refund_ticket_value, Decimal.new("0"))
    end

    test "explicit refund values persist for each grain kind", %{
      event_a: event,
      ticket: ticket,
      source_a: source
    } do
      refund_qty = 1
      refund_val = Decimal.new("25.50")

      ticket_type_snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :ticket_type,
          ticket_type_id: ticket.id,
          refund_ticket_quantity: refund_qty,
          refund_ticket_value: refund_val
        })

      assert ticket_type_snapshot.refund_ticket_quantity == refund_qty
      assert Decimal.equal?(ticket_type_snapshot.refund_ticket_value, refund_val)

      product_snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :source_product,
          source_system_id: source.id,
          woo_product_id: 88_001,
          refund_ticket_quantity: refund_qty,
          refund_ticket_value: refund_val
        })

      assert product_snapshot.refund_ticket_quantity == refund_qty
      assert Decimal.equal?(product_snapshot.refund_ticket_value, refund_val)

      variation_snapshot =
        create_snapshot!(%{
          event_id: event.id,
          dimension_kind: :source_variation,
          source_system_id: source.id,
          woo_product_id: 88_002,
          woo_variation_id: 98_002,
          refund_ticket_quantity: refund_qty,
          refund_ticket_value: refund_val
        })

      assert variation_snapshot.refund_ticket_quantity == refund_qty
      assert Decimal.equal?(variation_snapshot.refund_ticket_value, refund_val)
    end
  end

  describe "schema non-goals" do
    test "dimension snapshot does not persist derived net or average fields" do
      attributes =
        EventDimensionAggregateSnapshot
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)

      refute :net_ticket_quantity in attributes
      refute :net_ticket_value in attributes
      refute :average_ticket_value in attributes
    end
  end

  describe "invalid grain shapes" do
    test "ticket_type missing ticket_type_id fails", %{event_a: event} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type
               })
    end

    test "ticket_type carrying source/product fields fails", %{
      event_a: event,
      ticket: ticket,
      source_a: source
    } do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id,
                 source_system_id: source.id
               })
    end

    test "source_product missing source_system_id fails", %{event_a: event} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 woo_product_id: 99
               })
    end

    test "source_product missing woo_product_id fails", %{event_a: event, source_a: source} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 source_system_id: source.id
               })
    end

    test "source_product carrying woo_variation_id fails", %{event_a: event, source_a: source} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 source_system_id: source.id,
                 woo_product_id: 88,
                 woo_variation_id: 77
               })
    end

    test "source_variation missing woo_variation_id fails", %{event_a: event, source_a: source} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_variation,
                 source_system_id: source.id,
                 woo_product_id: 66
               })
    end

    test "mixed cross-kind shape fails", %{event_a: event, source_a: source} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 ticket_type_id: Ecto.UUID.generate(),
                 source_system_id: source.id,
                 woo_product_id: 55
               })
    end
  end

  describe "uniqueness" do
    test "duplicate ticket_type grain fails", %{event_a: event, ticket: ticket} do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id
               })

      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id
               })
    end

    test "duplicate source_product grain fails even with NULL variation", %{
      event_a: event,
      source_a: source
    } do
      attrs = %{
        event_id: event.id,
        dimension_kind: :source_product,
        source_system_id: source.id,
        woo_product_id: 42_001
      }

      assert {:ok, _} = create_snapshot(attrs)
      assert {:error, _} = create_snapshot(attrs)
    end

    test "duplicate source_variation grain fails", %{event_a: event, source_a: source} do
      attrs = %{
        event_id: event.id,
        dimension_kind: :source_variation,
        source_system_id: source.id,
        woo_product_id: 42_002,
        woo_variation_id: 52_002
      }

      assert {:ok, _} = create_snapshot(attrs)
      assert {:error, _} = create_snapshot(attrs)
    end
  end

  describe "isolation" do
    test "same product id across two source systems is allowed", %{
      event_a: event_a,
      event_b: event_b,
      source_a: source_a,
      source_b: source_b
    } do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event_a.id,
                 dimension_kind: :source_product,
                 source_system_id: source_a.id,
                 woo_product_id: 7_777
               })

      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event_b.id,
                 dimension_kind: :source_product,
                 source_system_id: source_b.id,
                 woo_product_id: 7_777
               })
    end

    test "same grain across two events is allowed", %{
      event_a: event_a,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket
    } do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event_a.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id
               })

      assert {:ok, _} =
               create_snapshot(%{
                 event_id: other_event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: other_ticket.id
               })
    end

    test "same grain across two currencies is allowed", %{event_a: event, ticket: ticket} do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 currency: "ZAR",
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id
               })

      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 currency: "USD",
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id
               })
    end
  end

  describe "relationship integrity" do
    test "ticket type from another event fails", %{event_a: event, other_ticket: other_ticket} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: other_ticket.id
               })
    end

    test "inactive ticket type succeeds", %{event_a: event, inactive_ticket: inactive_ticket} do
      assert {:ok, snapshot} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: inactive_ticket.id
               })

      assert snapshot.ticket_type_id == inactive_ticket.id
    end

    test "product grain event/source mismatch fails", %{event_a: event, source_b: source_b} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 source_system_id: source_b.id,
                 woo_product_id: 11_001
               })
    end

    test "variation grain event/source mismatch fails", %{event_a: event, source_b: source_b} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_variation,
                 source_system_id: source_b.id,
                 woo_product_id: 11_002,
                 woo_variation_id: 21_002
               })
    end

    test "matching event and source for product grain succeeds", %{
      event_a: event,
      source_a: source
    } do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 source_system_id: source.id,
                 woo_product_id: 11_003
               })
    end

    test "matching event and source for variation grain succeeds", %{
      event_a: event,
      source_a: source
    } do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_variation,
                 source_system_id: source.id,
                 woo_product_id: 11_004,
                 woo_variation_id: 21_004
               })
    end
  end

  describe "numeric integrity" do
    test "negative gross_ticket_quantity fails", %{event_a: event, ticket: ticket} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id,
                 gross_ticket_quantity: -1
               })
    end

    test "negative gross_ticket_value fails", %{event_a: event, ticket: ticket} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id,
                 gross_ticket_value: Decimal.new("-0.01")
               })
    end

    test "negative refund_ticket_quantity fails", %{event_a: event, ticket: ticket} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id,
                 refund_ticket_quantity: -1
               })
    end

    test "negative refund_ticket_value fails", %{event_a: event, ticket: ticket} do
      assert {:error, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :ticket_type,
                 ticket_type_id: ticket.id,
                 refund_ticket_value: Decimal.new("-0.01")
               })
    end
  end

  describe "database constraints" do
    test "postgres grain shape check rejects malformed rows", %{event_a: event, ticket: ticket} do
      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               insert_raw_snapshot(%{
                 event_id: event.id,
                 dimension_kind: "ticket_type",
                 ticket_type_id: ticket.id,
                 woo_product_id: 12_345
               })

      assert constraint == @grain_shape_constraint
    end

    test "postgres partial unique index rejects duplicate source_product grain", %{
      event_a: event,
      source_a: source
    } do
      assert {:ok, _} =
               create_snapshot(%{
                 event_id: event.id,
                 dimension_kind: :source_product,
                 source_system_id: source.id,
                 woo_product_id: 99_001
               })

      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               insert_raw_snapshot(%{
                 event_id: event.id,
                 dimension_kind: "source_product",
                 source_system_id: source.id,
                 woo_product_id: 99_001
               })

      assert constraint == @source_product_unique_index
    end

    test "postgres refund_ticket_quantity check rejects negative values", %{
      event_a: event,
      ticket: ticket
    } do
      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               insert_raw_snapshot(%{
                 event_id: event.id,
                 dimension_kind: "ticket_type",
                 ticket_type_id: ticket.id,
                 refund_ticket_quantity: -1
               })

      assert constraint == @refund_quantity_constraint
    end

    test "postgres refund_ticket_value check rejects negative values", %{
      event_a: event,
      ticket: ticket
    } do
      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               insert_raw_snapshot(%{
                 event_id: event.id,
                 dimension_kind: "ticket_type",
                 ticket_type_id: ticket.id,
                 refund_ticket_value: Decimal.new("-0.01")
               })

      assert constraint == @refund_value_constraint
    end
  end

  defp create_snapshot(attrs) do
    Ash.create(
      EventDimensionAggregateSnapshot,
      snapshot_attrs(attrs),
      action: :create_snapshot,
      domain: Analytics
    )
  end

  defp create_snapshot!(attrs) do
    Ash.create!(
      EventDimensionAggregateSnapshot,
      snapshot_attrs(attrs),
      action: :create_snapshot,
      domain: Analytics
    )
  end

  defp snapshot_attrs(attrs) do
    Map.merge(
      %{
        currency: "ZAR",
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("100.00"),
        refreshed_at: @refreshed_at
      },
      Map.new(attrs)
    )
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp insert_raw_snapshot(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      currency: "ZAR",
      dimension_kind: "ticket_type",
      ticket_type_id: nil,
      source_system_id: nil,
      woo_product_id: nil,
      woo_variation_id: nil,
      gross_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_quantity: 0,
      refund_ticket_value: Decimal.new("0"),
      refreshed_at: @refreshed_at,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    row = Map.merge(defaults, attrs)

    Repo.query(
      """
      INSERT INTO analytics_event_dimension_aggregate_snapshots
      (id, event_id, currency, dimension_kind, ticket_type_id, source_system_id,
       woo_product_id, woo_variation_id, gross_ticket_quantity, gross_ticket_value,
       refund_ticket_quantity, refund_ticket_value, refreshed_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
      """,
      [
        Ecto.UUID.dump!(row.id),
        Ecto.UUID.dump!(row.event_id),
        row.currency,
        row.dimension_kind,
        dump_optional_uuid(row.ticket_type_id),
        dump_optional_uuid(row.source_system_id),
        row.woo_product_id,
        row.woo_variation_id,
        row.gross_ticket_quantity,
        row.gross_ticket_value,
        row.refund_ticket_quantity,
        row.refund_ticket_value,
        row.refreshed_at,
        row.inserted_at,
        row.updated_at
      ]
    )
  end

  defp dump_optional_uuid(nil), do: nil
  defp dump_optional_uuid(id), do: Ecto.UUID.dump!(id)
end
