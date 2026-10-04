defmodule EventSales.Analytics.PeriodDimensionAggregatorTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Analytics.PeriodDimensionAggregator

  @instant ~U[2026-07-01 10:15:00.123456Z]
  @other_instant ~U[2026-07-03 12:45:00.654321Z]

  test "groups sale and refund facts into independent families and sums one grain" do
    event_id = Ecto.UUID.generate()
    ticket_type_id = Ecto.UUID.generate()
    source_system_id = Ecto.UUID.generate()

    matching_facts = [
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :sale,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("100.00")
      ),
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :refund,
        gross_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("0"),
        refund_ticket_quantity: 1,
        refund_ticket_value: Decimal.new("12.50")
      )
    ]

    pending = pending_for(event_id, "ZAR", @instant)

    assert {:ok, rows} =
             PeriodDimensionAggregator.rows_for_pending_buckets(matching_facts, pending)

    assert length(rows) == 6

    for bucket <- pending do
      bucket_rows = rows_for_bucket(rows, bucket)

      assert Enum.map(bucket_rows, & &1.dimension_kind) |> Enum.sort() == [
               :source_product,
               :source_variation,
               :ticket_type
             ]

      assert Enum.all?(bucket_rows, &(&1.gross_ticket_quantity == 2))
      assert Enum.all?(bucket_rows, &Decimal.equal?(&1.gross_ticket_value, Decimal.new("100.00")))
      assert Enum.all?(bucket_rows, &(&1.refund_ticket_quantity == 1))
      assert Enum.all?(bucket_rows, &Decimal.equal?(&1.refund_ticket_value, Decimal.new("12.50")))
    end
  end

  test "omits source variation for a no-variation fact and preserves a value-only refund" do
    event_id = Ecto.UUID.generate()
    ticket_type_id = Ecto.UUID.generate()
    source_system_id = Ecto.UUID.generate()

    matching_facts = [
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: nil,
        contribution_kind: :sale,
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("20.00")
      ),
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: nil,
        contribution_kind: :refund,
        gross_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("0"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("4.25")
      )
    ]

    assert {:ok, rows} =
             PeriodDimensionAggregator.rows_for_pending_buckets(
               matching_facts,
               pending_for(event_id, "ZAR", @instant)
             )

    assert Enum.all?(rows, &(&1.dimension_kind in [:ticket_type, :source_product]))
    assert length(rows) == 4
    assert Enum.all?(rows, &(&1.refund_ticket_quantity == 0))
    assert Enum.all?(rows, &Decimal.equal?(&1.refund_ticket_value, Decimal.new("4.25")))
  end

  test "keeps currencies and buckets separate and emits only pending identities" do
    event_id = Ecto.UUID.generate()
    ticket_type_id = Ecto.UUID.generate()
    source_system_id = Ecto.UUID.generate()

    matching_facts = [
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :sale
      ),
      fact(event_id, "EUR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :sale
      )
    ]

    pending = pending_for(event_id, "ZAR", @instant) ++ pending_for(event_id, "EUR", @instant)

    assert {:ok, rows} =
             PeriodDimensionAggregator.rows_for_pending_buckets(matching_facts, pending)

    assert Enum.count(rows, &(&1.currency == "ZAR")) == 6
    assert Enum.count(rows, &(&1.currency == "EUR")) == 6

    refute Enum.any?(
             rows,
             &(&1.bucket_start_utc == hd(bucket_for(@other_instant)).bucket_start_utc)
           )

    assert {:error, {:dimension_pending_bucket_missing, ^event_id, "ZAR", @other_instant}} =
             PeriodDimensionAggregator.rows_for_pending_buckets(
               [
                 fact(event_id, "ZAR", @other_instant,
                   ticket_type_id: ticket_type_id,
                   source_system_id: source_system_id,
                   woo_product_id: 101,
                   woo_variation_id: 202,
                   contribution_kind: :sale
                 )
               ],
               pending_for(event_id, "ZAR", @instant)
             )
  end

  test "a pending Johannesburg day emits its contribution without rebuilding an unaffected hour" do
    event_id = Ecto.UUID.generate()

    pending_day =
      pending_for(event_id, "ZAR", @instant)
      |> Enum.filter(&(&1.bucket_kind == :johannesburg_day))

    assert {:ok, rows} =
             PeriodDimensionAggregator.rows_for_pending_buckets(
               [fact(event_id, "ZAR", @instant)],
               pending_day
             )

    assert Enum.map(rows, & &1.bucket_kind) |> Enum.uniq() == [:johannesburg_day]
    assert length(rows) == 3
  end

  test "malformed grouping identity fails closed" do
    event_id = Ecto.UUID.generate()
    pending = pending_for(event_id, "ZAR", @instant)
    base = fact(event_id, "ZAR", @instant)

    for malformed <- [
          %{base | ticket_type_id: nil},
          %{base | source_system_id: nil},
          %{base | woo_product_id: 0},
          %{base | woo_variation_id: 0}
        ] do
      assert {:error, {:invalid_dimension_fact, 0, _reason}} =
               PeriodDimensionAggregator.rows_for_pending_buckets([malformed], pending)
    end
  end

  test "all-zero primitive contributions emit no dimensional rows" do
    event_id = Ecto.UUID.generate()

    assert {:ok, []} =
             PeriodDimensionAggregator.rows_for_pending_buckets(
               [
                 fact(event_id, "ZAR", @instant,
                   gross_ticket_quantity: 0,
                   gross_ticket_value: Decimal.new("0"),
                   refund_ticket_quantity: 0,
                   refund_ticket_value: Decimal.new("0")
                 )
               ],
               pending_for(event_id, "ZAR", @instant)
             )
  end

  test "reconciles each family independently and uses the variation-bearing subset" do
    event_id = Ecto.UUID.generate()
    ticket_type_id = Ecto.UUID.generate()
    source_system_id = Ecto.UUID.generate()

    facts = [
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :sale,
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("10.00")
      ),
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: nil,
        contribution_kind: :sale,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("20.00")
      ),
      fact(event_id, "ZAR", @instant,
        ticket_type_id: ticket_type_id,
        source_system_id: source_system_id,
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :refund,
        gross_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("0"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("2.00")
      )
    ]

    pending = pending_for(event_id, "ZAR", @instant)
    assert {:ok, rows} = PeriodDimensionAggregator.rows_for_pending_buckets(facts, pending)

    assert {:ok, variation_totals} =
             PeriodDimensionAggregator.variation_subset_totals_for_pending_buckets(facts, pending)

    event_totals =
      Map.new(pending, fn bucket ->
        {bucket_key(bucket),
         %{
           gross_ticket_quantity: 3,
           gross_ticket_value: Decimal.new("30.00"),
           refund_ticket_quantity: 0,
           refund_ticket_value: Decimal.new("2.00")
         }}
      end)

    assert :ok =
             PeriodDimensionAggregator.reconcile_rows(
               rows,
               pending,
               event_totals,
               variation_totals
             )

    for family <- [:ticket_type, :source_product, :source_variation] do
      incomplete = Enum.reject(rows, &(&1.dimension_kind == family))

      assert {:error, {:dimension_reconciliation_failed, ^family}} =
               PeriodDimensionAggregator.reconcile_rows(
                 incomplete,
                 pending,
                 event_totals,
                 variation_totals
               )

      corrupted =
        Enum.map(rows, fn row ->
          if row.dimension_kind == family,
            do: %{row | gross_ticket_quantity: row.gross_ticket_quantity + 1},
            else: row
        end)

      assert {:error, {:dimension_reconciliation_failed, ^family}} =
               PeriodDimensionAggregator.reconcile_rows(
                 corrupted,
                 pending,
                 event_totals,
                 variation_totals
               )
    end
  end

  defp fact(event_id, currency, effective_at, overrides \\ []) do
    Map.merge(
      %{
        event_id: event_id,
        currency: currency,
        effective_at: effective_at,
        ticket_type_id: Ecto.UUID.generate(),
        source_system_id: Ecto.UUID.generate(),
        woo_product_id: 101,
        woo_variation_id: 202,
        contribution_kind: :sale,
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("10.00"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("0")
      },
      Map.new(overrides)
    )
  end

  defp pending_for(event_id, currency, instant) do
    Enum.map(bucket_for(instant), fn bucket ->
      Map.merge(bucket, %{event_id: event_id, currency: currency})
    end)
  end

  defp bucket_for(instant) do
    {:ok, buckets} = PeriodBucketRules.for_instant(instant)
    buckets
  end

  defp bucket_key(bucket) do
    {bucket.event_id, bucket.currency, bucket.bucket_kind, bucket.bucket_start_utc,
     bucket.bucket_end_utc}
  end

  defp rows_for_bucket(rows, bucket) do
    Enum.filter(rows, fn row ->
      row.event_id == bucket.event_id and row.currency == bucket.currency and
        row.bucket_kind == bucket.bucket_kind and row.bucket_start_utc == bucket.bucket_start_utc and
        row.bucket_end_utc == bucket.bucket_end_utc
    end)
  end
end
