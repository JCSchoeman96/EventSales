defmodule EventSales.TestSupport.SalesHelpers do
  @moduledoc """
  Test-only helpers for Slice 4.0 sales storage tests.

  Slice 4.0 fixture helpers may use synthetic WooCommerce JSON
  (`order_completed`, `order_mixed_event`, etc.) for storage shape coverage only.
  Fixtures are Slice 1.6 synthetic placeholders — not parser validation or real
  payload verification (Slice 1.6 / 7.0).
  """

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.FixtureHelpers

  @spec create_source_system!(keyword() | map()) :: SourceSystem.t()
  def create_source_system!(attrs \\ %{}) do
    defaults = %{
      name: "Woo Store",
      kind: :woocommerce,
      base_url: "https://store-#{System.unique_integer([:positive])}.example.test"
    }

    Ash.create!(SourceSystem, Map.merge(defaults, Map.new(attrs)),
      action: :create,
      domain: Catalog
    )
  end

  @spec create_event!(SourceSystem.t(), keyword() | map()) :: Event.t()
  def create_event!(source, attrs) do
    defaults = %{
      source_system_id: source.id,
      name: "Event",
      slug: "event-#{System.unique_integer([:positive])}",
      status: :active
    }

    Ash.create!(Event, Map.merge(defaults, Map.new(attrs)), action: :create, domain: Catalog)
  end

  @spec create_ticket_type!(Event.t(), keyword() | map()) :: TicketType.t()
  def create_ticket_type!(event, attrs) do
    defaults = %{event_id: event.id, name: "Ticket"}

    Ash.create!(TicketType, Map.merge(defaults, Map.new(attrs)), action: :create, domain: Catalog)
  end

  @doc """
  Creates a TicketType with canonical Woo variation identity for ProductMapping writes.
  """
  @spec create_variation_ticket_type!(Event.t(), pos_integer(), pos_integer(), keyword() | map()) ::
          TicketType.t()
  def create_variation_ticket_type!(event, woo_product_id, woo_variation_id, attrs \\ %{}) do
    defaults = %{
      name: "Variation Ticket",
      external_ticket_type_kind: :woo_variation,
      external_ticket_type_id: woo_variation_id,
      external_product_id: woo_product_id,
      external_variation_id: woo_variation_id
    }

    create_ticket_type!(event, Map.merge(defaults, Map.new(attrs)))
  end

  @spec normalized_order_attrs_from_fixture!(atom() | String.t(), SourceSystem.t()) :: map()
  def normalized_order_attrs_from_fixture!(fixture_name, source) do
    fixture_name
    |> then(&FixtureHelpers.decode_json_fixture!(:woocommerce, &1))
    |> Map.merge(%{"source_system_id" => source.id})
    |> order_attrs_from_payload()
  end

  @spec create_order_from_fixture!(atom() | String.t(), SourceSystem.t()) :: Order.t()
  def create_order_from_fixture!(fixture_name, source) do
    attrs = normalized_order_attrs_from_fixture!(fixture_name, source)

    Ash.create!(Order, attrs, action: :create_normalized, domain: Sales)
  end

  @spec create_order_item_from_line!(Order.t(), map(), map()) :: OrderItem.t()
  def create_order_item_from_line!(order, line, opts \\ %{}) do
    defaults = %{
      order_id: order.id,
      woo_line_item_id: line["id"],
      woo_product_id: line["product_id"],
      woo_variation_id: line["variation_id"],
      name: line["name"],
      quantity: line["quantity"],
      line_subtotal: decimal!(line["subtotal"]),
      line_total: decimal!(line["total"]),
      discount_total: decimal!(line["discount_total"] || "0"),
      item_kind: :unknown,
      mapping_status: :pending_mapping_resolution
    }

    attrs = defaults |> Map.merge(Map.new(opts))

    Ash.create!(OrderItem, attrs, action: :create_normalized, domain: Sales)
  end

  @spec create_mixed_event_order!(SourceSystem.t()) :: %{
          order: Order.t(),
          items: [OrderItem.t()],
          events: [Event.t()]
        }
  def create_mixed_event_order!(source) do
    payload = FixtureHelpers.decode_json_fixture!(:woocommerce, :order_mixed_event)
    order = create_order_from_fixture!(:order_mixed_event, source)

    event_a = create_event!(source, %{name: "Synthetic Event A", slug: "synthetic-event-a"})
    event_b = create_event!(source, %{name: "Synthetic Event B", slug: "synthetic-event-b"})
    ticket_a = create_ticket_type!(event_a, %{name: "GA"})
    ticket_b = create_ticket_type!(event_b, %{name: "VIP"})

    lines = payload["line_items"]

    item_a =
      create_order_item_from_line!(order, Enum.at(lines, 0), %{
        event_id: event_a.id,
        ticket_type_id: ticket_a.id,
        mapping_status: :mapped,
        item_kind: :ticket
      })

    item_b =
      create_order_item_from_line!(order, Enum.at(lines, 1), %{
        event_id: event_b.id,
        ticket_type_id: ticket_b.id,
        mapping_status: :mapped,
        item_kind: :ticket
      })

    %{order: order, items: [item_a, item_b], events: [event_a, event_b]}
  end

  defp order_attrs_from_payload(payload) do
    billing = payload["billing"] || %{}

    %{
      source_system_id: payload["source_system_id"],
      woo_order_id: payload["id"],
      order_number: payload["number"],
      status: String.to_existing_atom(payload["status"]),
      currency: payload["currency"],
      completed_at: parse_gmt(payload["date_completed_gmt"]),
      created_at_source: parse_gmt!(payload["date_created_gmt"]),
      updated_at_source: parse_gmt!(payload["date_modified_gmt"]),
      customer_name: "#{billing["first_name"]} #{billing["last_name"]}" |> String.trim(),
      customer_email: billing["email"],
      raw_total: decimal!(payload["total"]),
      raw_discount_total: decimal!(payload["discount_total"] || "0"),
      raw_tax_total: decimal!(payload["total_tax"] || "0")
    }
  end

  defp parse_gmt!(value) when is_binary(value) do
    value
    |> NaiveDateTime.from_iso8601!()
    |> DateTime.from_naive!("Etc/UTC")
  end

  defp parse_gmt(nil), do: nil
  defp parse_gmt(value), do: parse_gmt!(value)

  defp decimal!(value) when is_binary(value), do: Decimal.new(value)
  defp decimal!(%Decimal{} = value), do: value
end
