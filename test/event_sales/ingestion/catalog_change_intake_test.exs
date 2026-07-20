defmodule EventSales.Ingestion.CatalogChangeIntakeTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.CatalogChangeIntake
  alias EventSales.Ingestion.Resources.{CatalogChangePendingTarget, CatalogChangeSignal}
  alias EventSales.TestSupport.SalesHelpers

  @payload %{
    "version" => "2026-07-20.v1",
    "signal_id" => "0190d5d4-7b86-7ae2-8d90-70ea430a87c4",
    "source" => "wordpress_tickera",
    "target_type" => "product",
    "target_id" => 123,
    "source_updated_at" => "2026-07-20T12:00:00.000000Z",
    "reason" => "metadata_changed"
  }

  test "accepts once, keeps receipt immutable, and advances generation only for new signals" do
    source = SalesHelpers.create_source_system!()
    body = Jason.encode!(@payload)

    assert {:ok, :accepted} = CatalogChangeIntake.persist(source.id, body, @payload)
    assert {:ok, :duplicate} = CatalogChangeIntake.persist(source.id, body, @payload)

    assert {:ok, [receipt]} = Ash.read(CatalogChangeSignal)
    assert receipt.payload_hash == hash(body)
    assert {:ok, [target]} = Ash.read(CatalogChangePendingTarget)
    assert target.generation == 1

    newer = %{
      @payload
      | "signal_id" => Ecto.UUID.generate(),
        "source_updated_at" => "2026-07-20T12:00:01Z"
    }

    assert {:ok, :accepted} = CatalogChangeIntake.persist(source.id, Jason.encode!(newer), newer)
    assert {:ok, [target]} = Ash.read(CatalogChangePendingTarget)
    assert target.generation == 2
  end

  test "rejects a reused signal id with a different body without mutation" do
    source = SalesHelpers.create_source_system!()
    body = Jason.encode!(@payload)
    assert {:ok, :accepted} = CatalogChangeIntake.persist(source.id, body, @payload)

    mismatch = %{@payload | "reason" => "saved"}

    assert {:error, :signal_id_payload_mismatch} =
             CatalogChangeIntake.persist(source.id, Jason.encode!(mismatch), mismatch)

    assert {:ok, [target]} = Ash.read(CatalogChangePendingTarget)
    assert target.generation == 1
  end

  defp hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
