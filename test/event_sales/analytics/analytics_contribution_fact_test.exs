defmodule EventSales.Analytics.AnalyticsContributionFactTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.AnalyticsContributionFact
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @effective_at ~U[2026-05-18 08:30:00.000000Z]
  @refreshed_at ~U[2026-05-18 09:05:00.000000Z]

  @source_identity_index "analytics_contribution_facts_source_identity_uidx"
  @primitive_shape_constraint "analytics_contribution_facts_kind_shape_check"
  @coverage_identity_constraint "analytics_contribution_facts_coverage_identity_check"
  @primitive_constraints %{
    gross_ticket_quantity: "analytics_contribution_facts_gross_quantity_check",
    gross_ticket_value: "analytics_contribution_facts_gross_value_check",
    refund_ticket_quantity: "analytics_contribution_facts_refund_quantity_check",
    refund_ticket_value: "analytics_contribution_facts_refund_value_check"
  }
  @woo_constraints %{
    woo_product_id: "analytics_contribution_facts_woo_product_id_check",
    woo_variation_id: "analytics_contribution_facts_woo_variation_id_check"
  }

  setup do
    source_a = SalesHelpers.create_source_system!(%{name: "Contribution Source A"})
    source_b = SalesHelpers.create_source_system!(%{name: "Contribution Source B"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Contribution Event A",
        slug: unique_slug("contribution-a")
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Contribution Event B",
        slug: unique_slug("contribution-b")
      })

    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "GA"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Other GA"})

    %{
      source_a: source_a,
      source_b: source_b,
      event_a: event_a,
      event_b: event_b,
      ticket_a: ticket_a,
      ticket_b: ticket_b
    }
  end

  test "creates a qualifying sale fact", %{event_a: event, ticket_a: ticket, source_a: source} do
    assert {:ok, fact} =
             create_fact(%{
               event_id: event.id,
               ticket_type_id: ticket.id,
               source_system_id: source.id
             })

    assert fact.contribution_kind == :sale
    assert fact.gross_ticket_quantity == 1
    assert fact.refund_ticket_quantity == 0
  end

  test "creates a quantity refund fact", %{event_a: event, ticket_a: ticket, source_a: source} do
    assert {:ok, fact} =
             create_fact(%{
               event_id: event.id,
               ticket_type_id: ticket.id,
               source_system_id: source.id,
               contribution_kind: :refund,
               gross_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("0"),
               refund_ticket_quantity: 1,
               refund_ticket_value: Decimal.new("0")
             })

    assert fact.refund_ticket_quantity == 1
  end

  test "creates a value-only refund fact", %{event_a: event, ticket_a: ticket, source_a: source} do
    assert {:ok, fact} =
             create_fact(%{
               event_id: event.id,
               ticket_type_id: ticket.id,
               source_system_id: source.id,
               contribution_kind: :refund,
               gross_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("0"),
               refund_ticket_quantity: 0,
               refund_ticket_value: Decimal.new("25.50")
             })

    assert fact.refund_ticket_quantity == 0
    assert Decimal.equal?(fact.refund_ticket_value, Decimal.new("25.50"))
  end

  test "empty coverage identity fails through Ash", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    assert {:error, _} =
             create_fact(%{
               event_id: event.id,
               ticket_type_id: ticket.id,
               source_system_id: source.id,
               coverage_identity: ""
             })
  end

  test "same kind and source UUID cannot be inserted twice", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    attrs = %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      source_system_id: source.id,
      source_contribution_id: Ecto.UUID.generate()
    }

    assert {:ok, _} = create_fact(attrs)
    assert {:error, _} = create_fact(attrs)
  end

  test "the same UUID under a different contribution kind does not collide", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    source_id = Ecto.UUID.generate()
    identity = %{event_id: event.id, ticket_type_id: ticket.id, source_system_id: source.id}

    assert {:ok, _} = create_fact(Map.put(identity, :source_contribution_id, source_id))

    assert {:ok, _} =
             create_fact(
               Map.merge(identity, %{
                 source_contribution_id: source_id,
                 contribution_kind: :refund,
                 gross_ticket_quantity: 0,
                 gross_ticket_value: Decimal.new("0"),
                 refund_ticket_quantity: 0,
                 refund_ticket_value: Decimal.new("10")
               })
             )
  end

  test "rejects empty refunds and mixed sale/refund primitives", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    identity = %{event_id: event.id, ticket_type_id: ticket.id, source_system_id: source.id}

    assert {:error, _} =
             create_fact(
               Map.merge(identity, %{
                 contribution_kind: :refund,
                 gross_ticket_quantity: 0,
                 gross_ticket_value: Decimal.new("0"),
                 refund_ticket_quantity: 0,
                 refund_ticket_value: Decimal.new("0")
               })
             )

    assert {:error, _} =
             create_fact(
               Map.merge(identity, %{
                 refund_ticket_quantity: 1
               })
             )

    assert {:error, _} =
             create_fact(
               Map.merge(identity, %{
                 contribution_kind: :refund,
                 gross_ticket_quantity: 1,
                 refund_ticket_quantity: 1
               })
             )
  end

  test "rejects negative primitives and non-positive Woo IDs", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    identity = %{event_id: event.id, ticket_type_id: ticket.id, source_system_id: source.id}

    for {field, value} <- [
          gross_ticket_quantity: -1,
          gross_ticket_value: Decimal.new("-0.01"),
          refund_ticket_quantity: -1,
          refund_ticket_value: Decimal.new("-0.01"),
          woo_product_id: 0,
          woo_variation_id: -1
        ] do
      assert {:error, _} = create_fact(Map.put(identity, field, value))
    end
  end

  test "ticket type and source system must match the event", %{
    event_a: event,
    ticket_a: ticket_a,
    ticket_b: ticket_b,
    source_b: source_b
  } do
    assert {:error, _} =
             create_fact(%{
               event_id: event.id,
               ticket_type_id: ticket_b.id,
               source_system_id: event.source_system_id
             })

    assert {:error, _} =
             create_fact(%{
               event_id: event.id,
               ticket_type_id: ticket_a.id,
               source_system_id: source_b.id
             })
  end

  test "does not persist derived metrics or projection state" do
    attributes =
      AnalyticsContributionFact
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    refute :net_ticket_quantity in attributes
    refute :net_ticket_value in attributes
    refute :average_ticket_value in attributes
    refute :absolute_delta in attributes
    refute :percentage_delta in attributes
    refute :projection_state in attributes
  end

  test "resource is registered in the analytics domain" do
    assert AnalyticsContributionFact in Ash.Domain.Info.resources(Analytics)
  end

  test "postgres source identity index rejects a duplicate", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    attrs = %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      source_system_id: source.id,
      source_contribution_id: Ecto.UUID.generate()
    }

    assert {:ok, _} = create_fact(attrs)

    assert {:error, %Postgrex.Error{postgres: %{constraint: @source_identity_index}}} =
             insert_raw_fact(snapshot_attrs(attrs))
  end

  test "postgres primitive-kind check rejects an empty refund", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    attrs =
      snapshot_attrs(%{
        event_id: event.id,
        ticket_type_id: ticket.id,
        source_system_id: source.id,
        contribution_kind: "refund",
        gross_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("0"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("0")
      })

    assert {:error, %Postgrex.Error{postgres: %{constraint: @primitive_shape_constraint}}} =
             insert_raw_fact(attrs)
  end

  test "postgres check rejects an empty coverage identity", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    assert {:error, %Postgrex.Error{postgres: %{constraint: @coverage_identity_constraint}}} =
             insert_raw_fact(%{
               event_id: event.id,
               ticket_type_id: ticket.id,
               source_system_id: source.id,
               coverage_identity: ""
             })
  end

  test "postgres checks reject negative primitives and non-positive product IDs", %{
    event_a: event,
    ticket_a: ticket,
    source_a: source
  } do
    identity = %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      source_system_id: source.id
    }

    for {field, _constraint} <- @primitive_constraints do
      value =
        if field in [:gross_ticket_quantity, :refund_ticket_quantity],
          do: -1,
          else: Decimal.new("-0.01")

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               insert_raw_fact(snapshot_attrs(Map.put(identity, field, value)))
    end

    for {field, constraint} <- @woo_constraints do
      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               insert_raw_fact(snapshot_attrs(Map.put(identity, field, 0)))
    end
  end

  defp create_fact(attrs) do
    Ash.create(
      AnalyticsContributionFact,
      snapshot_attrs(attrs),
      action: :create_fact,
      domain: Analytics
    )
  end

  defp snapshot_attrs(attrs) do
    Map.merge(
      %{
        contribution_kind: :sale,
        source_contribution_id: Ecto.UUID.generate(),
        currency: "ZAR",
        effective_at: @effective_at,
        woo_product_id: 81_001,
        woo_variation_id: nil,
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("100.00"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("0"),
        generation_id: Ecto.UUID.generate(),
        semantic_version: 1,
        coverage_identity: "m5_04_coverage_v1",
        refreshed_at: @refreshed_at,
        source_watermark_at: nil
      },
      Map.new(attrs)
    )
  end

  defp insert_raw_fact(attrs) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          contribution_kind: "sale",
          source_contribution_id: Ecto.UUID.generate(),
          currency: "ZAR",
          effective_at: @effective_at,
          woo_product_id: 81_001,
          woo_variation_id: nil,
          gross_ticket_quantity: 1,
          gross_ticket_value: Decimal.new("100.00"),
          refund_ticket_quantity: 0,
          refund_ticket_value: Decimal.new("0"),
          generation_id: Ecto.UUID.generate(),
          semantic_version: 1,
          coverage_identity: "m5_04_coverage_v1",
          refreshed_at: @refreshed_at,
          source_watermark_at: nil,
          inserted_at: @refreshed_at,
          updated_at: @refreshed_at
        },
        attrs
      )
      |> Map.update!(:contribution_kind, &to_string/1)

    Repo.query(
      """
      INSERT INTO analytics_contribution_facts
      (id, contribution_kind, source_contribution_id, event_id, currency,
       effective_at, ticket_type_id, source_system_id, woo_product_id,
       woo_variation_id, gross_ticket_quantity, gross_ticket_value,
       refund_ticket_quantity, refund_ticket_value, generation_id,
       semantic_version, coverage_identity, refreshed_at, source_watermark_at,
       inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
              $14, $15, $16, $17, $18, $19, $20, $21)
      """,
      [
        Ecto.UUID.dump!(row.id),
        row.contribution_kind,
        Ecto.UUID.dump!(row.source_contribution_id),
        Ecto.UUID.dump!(row.event_id),
        row.currency,
        row.effective_at,
        Ecto.UUID.dump!(row.ticket_type_id),
        Ecto.UUID.dump!(row.source_system_id),
        row.woo_product_id,
        row.woo_variation_id,
        row.gross_ticket_quantity,
        row.gross_ticket_value,
        row.refund_ticket_quantity,
        row.refund_ticket_value,
        Ecto.UUID.dump!(row.generation_id),
        row.semantic_version,
        row.coverage_identity,
        row.refreshed_at,
        row.source_watermark_at,
        row.inserted_at,
        row.updated_at
      ]
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
