defmodule EventSales.Catalog.EventImporterTest do
  use EventSales.DataCase, async: true

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.EventImporter
  alias EventSales.Catalog.Resources.Event
  alias EventSales.TestSupport.SalesHelpers

  test "missing exact event creates once" do
    source = SalesHelpers.create_source_system!()

    assert {:ok, %{event: event, outcome: :created}} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 12_345,
               name: "Concert 2026",
               slug: "concert-2026"
             })

    assert event.source_system_id == source.id
    assert event.external_event_kind == :tickera_event
    assert event.external_event_id == 12_345
    assert event.name == "Concert 2026"
    assert event.slug == "concert-2026"
    assert matching_event_count(source.id, 12_345) == 1
  end

  test "replay is idempotent and returns same event" do
    source = SalesHelpers.create_source_system!()

    attrs = %{
      external_event_id: 55_001,
      name: "Replay Concert",
      slug: "replay-concert"
    }

    assert {:ok, %{event: first, outcome: :created}} =
             EventImporter.import_tickera_event(source.id, attrs)

    assert {:ok, %{event: second, outcome: :existing}} =
             EventImporter.import_tickera_event(source.id, attrs)

    assert {:ok, %{event: third, outcome: :existing}} =
             EventImporter.import_tickera_event(source.id, attrs)

    assert first.id == second.id
    assert second.id == third.id
    assert matching_event_count(source.id, 55_001) == 1
  end

  test "existing exact event is reused without duplicate" do
    source = SalesHelpers.create_source_system!()

    existing =
      SalesHelpers.create_event!(source, %{
        name: "Preexisting",
        slug: "preexisting",
        external_event_kind: :tickera_event,
        external_event_id: 77_001
      })

    assert {:ok, %{event: resolved, outcome: :existing}} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 77_001,
               name: "Preexisting",
               slug: "preexisting"
             })

    assert resolved.id == existing.id
    assert matching_event_count(source.id, 77_001) == 1
  end

  test "same numeric event id across two sources remains isolated" do
    source_a = SalesHelpers.create_source_system!(%{base_url: "https://a-import.example.test"})
    source_b = SalesHelpers.create_source_system!(%{base_url: "https://b-import.example.test"})

    assert {:ok, %{event: event_a, outcome: :created}} =
             EventImporter.import_tickera_event(source_a.id, %{
               external_event_id: 123,
               name: "Source A Concert",
               slug: "source-a-concert"
             })

    assert {:ok, %{event: event_b, outcome: :created}} =
             EventImporter.import_tickera_event(source_b.id, %{
               external_event_id: 123,
               name: "Source B Concert",
               slug: "source-b-concert"
             })

    refute event_a.id == event_b.id
    assert event_a.source_system_id == source_a.id
    assert event_b.source_system_id == source_b.id
    assert matching_event_count(source_a.id, 123) == 1
    assert matching_event_count(source_b.id, 123) == 1
  end

  test "missing source system fails closed without creating" do
    missing_source_id = Ecto.UUID.generate()

    assert {:error, :source_not_found} =
             EventImporter.import_tickera_event(missing_source_id, %{
               external_event_id: 88_001,
               name: "Missing Source Concert",
               slug: "missing-source-concert"
             })

    assert matching_event_count(missing_source_id, 88_001) == 0
  end

  test "slug collision with different external event fails closed" do
    source = SalesHelpers.create_source_system!()

    SalesHelpers.create_event!(source, %{
      name: "Existing Slug Owner",
      slug: "shared-slug",
      external_event_kind: :tickera_event,
      external_event_id: 1001
    })

    assert {:error, :slug_conflict} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 1002,
               name: "Different External Event",
               slug: "shared-slug"
             })

    assert matching_event_count(source.id, 1002) == 0
    assert matching_event_count(source.id, 1001) == 1
  end

  test "existing exact identity with changed mutable input remains same link" do
    source = SalesHelpers.create_source_system!()

    existing =
      SalesHelpers.create_event!(source, %{
        name: "Old Name",
        slug: "stable-slug",
        external_event_kind: :tickera_event,
        external_event_id: 66_001
      })

    assert {:ok, %{event: resolved, outcome: :existing}} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 66_001,
               name: "New Name",
               slug: "changed-slug"
             })

    assert resolved.id == existing.id
    assert resolved.name == "Old Name"
    assert resolved.slug == "stable-slug"
    assert matching_event_count(source.id, 66_001) == 1
  end

  test "invalid external event id fails closed" do
    source = SalesHelpers.create_source_system!()

    assert {:error, :invalid_external_event_id} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 0,
               name: "Bad",
               slug: "bad"
             })

    assert {:error, :invalid_input} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 1,
               name: "",
               slug: "ok"
             })
  end

  defp matching_event_count(source_system_id, external_event_id) do
    Event
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        external_event_kind == :tickera_event and
        external_event_id == ^external_event_id
    )
    |> Ash.read!(domain: Catalog)
    |> length()
  end
end
