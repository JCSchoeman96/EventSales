defmodule EventSales.Catalog.SourceEventResolverTest do
  use EventSales.DataCase, async: true

  alias EventSales.Catalog.SourceEventResolver
  alias EventSales.TestSupport.SalesHelpers

  test "exact source pk + tickera event resolves" do
    source = SalesHelpers.create_source_system!(%{base_url: "https://alpha.example.test"})

    event =
      SalesHelpers.create_event!(source, %{
        name: "Concert 2026",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    assert {:ok, %{source_system: resolved_source, event: resolved_event}} =
             SourceEventResolver.resolve(source.id, 123)

    assert resolved_source.id == source.id
    assert resolved_event.id == event.id
    assert resolved_event.source_system_id == source.id
    assert resolved_event.external_event_id == 123
    assert resolved_event.external_event_kind == :tickera_event
  end

  test "canonical source key + tickera event resolves" do
    source =
      SalesHelpers.create_source_system!(%{
        kind: :woocommerce,
        base_url: "https://canonical.example.test/"
      })

    event =
      SalesHelpers.create_event!(source, %{
        name: "Canonical Concert",
        external_event_kind: :tickera_event,
        external_event_id: 777
      })

    assert {:ok, %{source_system: resolved_source, event: resolved_event}} =
             SourceEventResolver.resolve(
               %{kind: :woocommerce, base_url: "https://canonical.example.test/"},
               777
             )

    assert resolved_source.id == source.id
    assert resolved_event.id == event.id
  end

  test "same numeric event id under another source does not contaminate" do
    source_a = SalesHelpers.create_source_system!(%{base_url: "https://a.example.test"})
    source_b = SalesHelpers.create_source_system!(%{base_url: "https://b.example.test"})

    event_a =
      SalesHelpers.create_event!(source_a, %{
        name: "Source A Concert",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    event_b =
      SalesHelpers.create_event!(source_b, %{
        name: "Source B Concert",
        external_event_kind: :tickera_event,
        external_event_id: 123
      })

    assert {:ok, %{source_system: resolved_source, event: resolved_event}} =
             SourceEventResolver.resolve(source_a.id, 123)

    assert resolved_source.id == source_a.id
    assert resolved_event.id == event_a.id
    refute resolved_event.id == event_b.id
    assert resolved_event.source_system_id == source_a.id
  end

  test "missing event fail closed" do
    source = SalesHelpers.create_source_system!()

    assert {:error, :event_not_found} = SourceEventResolver.resolve(source.id, 999_001)
  end

  test "missing source fail closed" do
    missing_source_id = Ecto.UUID.generate()

    assert {:error, :source_not_found} =
             SourceEventResolver.resolve(missing_source_id, 123)
  end

  test "missing canonical source key fail closed" do
    assert {:error, :source_not_found} =
             SourceEventResolver.resolve(
               %{kind: :woocommerce, base_url: "https://absent.example.test"},
               123
             )
  end

  test "name collision is irrelevant to identity" do
    source = SalesHelpers.create_source_system!()

    target =
      SalesHelpers.create_event!(source, %{
        name: "Concert 2026",
        external_event_kind: :tickera_event,
        external_event_id: 1001
      })

    _other =
      SalesHelpers.create_event!(source, %{
        name: "Concert 2026",
        external_event_kind: :tickera_event,
        external_event_id: 1002
      })

    assert {:ok, %{event: resolved_event}} = SourceEventResolver.resolve(source.id, 1001)
    assert resolved_event.id == target.id
    assert resolved_event.external_event_id == 1001
  end

  test "unsupported external event kind fail closed" do
    source = SalesHelpers.create_source_system!()

    SalesHelpers.create_event!(source, %{
      name: "Concert 2026",
      external_event_kind: :tickera_event,
      external_event_id: 55
    })

    assert {:error, :unsupported_external_event_kind} =
             SourceEventResolver.resolve(source.id, 55, external_event_kind: :other)
  end

  test "invalid external event id fail closed" do
    source = SalesHelpers.create_source_system!()

    assert {:error, :invalid_external_event_id} =
             SourceEventResolver.resolve(source.id, 0)

    assert {:error, :invalid_external_event_id} =
             SourceEventResolver.resolve(source.id, -1)
  end
end
