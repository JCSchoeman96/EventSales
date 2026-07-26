defmodule EventSales.Catalog.TickeraCatalog.NormalizerTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.{DiscoveryResult, Normalizer}
  alias EventSales.TestSupport.TickeraCatalogFixtures

  test "persists sorted v2 source risks for rows that are filtered from candidates" do
    event =
      TickeraCatalogFixtures.vwg_event()
      |> Map.merge(%{
        "event_status_classification" => "publish",
        "target_observation" => "present",
        "risk_codes" => []
      })

    row =
      TickeraCatalogFixtures.vwg_row()
      |> Map.merge(%{
        "product_status" => "private",
        "product_status_classification" => "private",
        "variation_status_classification" => nil,
        "product_type" => "simple",
        "ticket_template_present" => true,
        "subscription_classification" => "not_subscription",
        "product_semantics" => %{
          "payment_plan" => "unknown",
          "membership" => "unknown",
          "bundle" => "unknown",
          "add_on" => "unknown"
        },
        "target_observation" => "present",
        "risk_codes" => ["unknown_product_semantics", "private_product"]
      })

    result = %DiscoveryResult{
      schema_version: "2026-07-22.v2",
      auto_apply_proof_complete?: true,
      events: [event],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [], source_risks: risks, findings: findings}} =
             Normalizer.normalize(result)

    assert Enum.any?(
             risks,
             &(&1.code == :private_event and &1.evidence_classification == :explicit_safe)
           )

    assert Enum.any?(
             risks,
             &(&1.code == :private_product and &1.evidence_classification == :explicit_risky)
           )

    assert Enum.any?(
             risks,
             &(&1.code == :unknown_product_semantics and &1.evidence_classification == :unknown)
           )

    assert Enum.any?(findings, &(&1.code == :private_product))
  end

  test "missing v2 row risk proof fails closed with an explicit risk and finding" do
    result = %DiscoveryResult{
      schema_version: "2026-07-22.v2",
      auto_apply_proof_complete?: true,
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, %{source_risks: risks, findings: findings}} =
             Normalizer.normalize(result)

    assert Enum.count(risks, &(&1.code == :missing_source_risk_data)) == 2

    assert Enum.any?(
             risks,
             &(&1.code == :private_event and &1.evidence_classification == :explicit_safe)
           )

    assert Enum.any?(
             risks,
             &(&1.code == :private_product and &1.evidence_classification == :explicit_safe)
           )

    assert Enum.any?(findings, &(&1.code == :missing_source_risk_data))
  end

  test "normalizes VWG Pretoria as one product-level candidate" do
    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, %{rows: [row], findings: findings}} = Normalizer.normalize(result)

    assert row.tickera_event_id == 109_316
    assert row.woo_product_id == 109_740
    assert row.woo_variation_id == nil
    assert row.ticket_type_name == "VWG - Pretoria"
    assert row.ticket_type_kind == :woo_product
    assert row.starts_at == ~U[2026-08-01 16:00:00Z]
    assert row.ends_at == ~U[2026-08-01 18:00:00Z]
    assert row.venue_name == "Pretoria"
    assert row.booking_fee_type == :fixed
    assert row.booking_fee_value == Decimal.new("25.00")
    assert findings == []
  end

  test "normalizes invalid or unsupported event metadata as nil" do
    event =
      TickeraCatalogFixtures.vwg_event()
      |> Map.merge(%{
        "event_start_at" => "not-a-date",
        "event_end_at" => nil,
        "event_location" => " ",
        "booking_fee_type" => "per-seat",
        "booking_fee_value" => "not-money"
      })

    result = %DiscoveryResult{
      events: [event],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, %{rows: [row], findings: []}} = Normalizer.normalize(result)

    assert row.starts_at == nil
    assert row.ends_at == nil
    assert row.venue_name == nil
    assert row.booking_fee_type == nil
    assert row.booking_fee_value == nil
  end

  test "normalizes percentage booking fee type" do
    event =
      TickeraCatalogFixtures.vwg_event()
      |> Map.merge(%{
        "booking_fee_type" => "percentage",
        "booking_fee_value" => "12.5"
      })

    result = %DiscoveryResult{
      events: [event],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, %{rows: [row], findings: []}} = Normalizer.normalize(result)

    assert row.booking_fee_type == :percentage
    assert row.booking_fee_value == Decimal.new("12.5")
  end

  test "simple product falls back to ticket display name only when product title is missing" do
    row = Map.put(TickeraCatalogFixtures.vwg_row(), "product_title", nil)

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: []}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == "Toegang"
  end

  test "collapses duplicate meta rows without using price as identity" do
    row = TickeraCatalogFixtures.vwg_row()
    duplicate = Map.put(row, "price", "199.00")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [row, duplicate]
    }

    assert {:ok, %{rows: rows, findings: findings}} = Normalizer.normalize(result)

    assert length(rows) == 1
    assert [%{code: :duplicate_meta_collapsed, severity: :info}] = findings
  end

  test "skips private Tickera events even when Woo product is published" do
    event = %{
      "tickera_event_id" => 200_001,
      "event_title" => "Private Retreat",
      "event_slug" => "private-retreat",
      "event_status" => "private"
    }

    result = %DiscoveryResult{
      events: [event],
      catalog_rows: [TickeraCatalogFixtures.private_event_row()]
    }

    assert {:ok, %{rows: [], findings: findings}} = Normalizer.normalize(result)
    assert [%{code: :private_event_skipped, severity: :info}] = findings
  end

  test "warns when a published Tickera event has no eligible ticket products" do
    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.zero_product_event()],
      catalog_rows: []
    }

    assert {:ok, %{rows: [], findings: findings}} = Normalizer.normalize(result)
    assert [%{code: :published_event_without_ticket_products, severity: :warning}] = findings
  end

  test "variation products emit variation-level candidates only and warning" do
    [first_variation | _rest] = variation_rows = TickeraCatalogFixtures.variation_rows()

    parent_row =
      first_variation
      |> Map.put("woo_variation_id", nil)
      |> Map.put("variation_title", nil)
      |> Map.put("variation_status", nil)
      |> Map.put("variation_source_updated_at", nil)

    result = %DiscoveryResult{
      events: [
        %{
          "tickera_event_id" => 400_001,
          "event_title" => "Variation Event",
          "event_slug" => "variation-event",
          "event_status" => "publish"
        }
      ],
      catalog_rows: [parent_row | variation_rows]
    }

    assert {:ok, %{rows: rows, findings: findings}} = Normalizer.normalize(result)

    assert Enum.map(rows, & &1.woo_variation_id) == [400_741, 400_742]
    assert Enum.all?(rows, &(&1.ticket_type_kind == :woo_variation))
    assert Enum.any?(findings, &(&1.code == :variation_mapping_required))
    refute Enum.any?(rows, &is_nil(&1.woo_variation_id))
  end

  test "variation products use product title with prefixed variation option labels" do
    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: TickeraCatalogFixtures.lbl_variation_rows()
    }

    assert {:ok, %{rows: rows, findings: findings}} = Normalizer.normalize(result)

    assert Enum.map(rows, & &1.ticket_type_name) == [
             "LBL – Nelspruit [Kaartjie]",
             "LBL – Nelspruit [Kaartjie + 1 x Verloor gewig op jóú manier]"
           ]

    assert Enum.all?(rows, &(&1.ticket_display_name == "Toegang"))
    assert Enum.any?(findings, &(&1.code == :variation_mapping_required))
    refute Enum.any?(findings, &(&1.severity == :blocking))
  end

  test "variation product strips HTML separator span before prefix parsing" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "variation_title", "LBL – Nelspruit<span> - </span>Kaartjie")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == "LBL – Nelspruit [Kaartjie]"
    assert normalized.ticket_display_name == "Toegang"
    refute Enum.any?(findings, &(&1.severity == :blocking))
  end

  test "variation product strips HTML separator span for long option labels" do
    [_first, row] = TickeraCatalogFixtures.lbl_variation_rows()

    row =
      Map.put(
        row,
        "variation_title",
        "LBL – Nelspruit<span> - </span>Kaartjie + 1 x Verloor gewig op jóú manier"
      )

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name ==
             "LBL – Nelspruit [Kaartjie + 1 x Verloor gewig op jóú manier]"

    assert normalized.ticket_display_name == "Toegang"
    refute Enum.any?(findings, &(&1.severity == :blocking))
  end

  test "variation product decodes HTML entities before prefix parsing" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "variation_title", "LBL – Nelspruit&ndash;Kaartjie")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == "LBL – Nelspruit [Kaartjie]"
    refute Enum.any?(findings, &(&1.severity == :blocking))
  end

  test "HTML stripping does not affect simple product naming" do
    row = Map.put(TickeraCatalogFixtures.vwg_row(), "product_title", "VWG - Pretoria")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: []}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == "VWG - Pretoria"
  end

  test "variation product uses variation title directly when it is already an option label" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "variation_title", "Kaartjie")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == "LBL – Nelspruit [Kaartjie]"
    refute Enum.any?(findings, &(&1.severity == :blocking))
  end

  test "variation product strips supported product-title separators" do
    for {separator, option_label} <- [
          {" – ", "Kaartjie"},
          {" — ", "Kaartjie"},
          {": ", "Kaartjie"}
        ] do
      [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
      row = Map.put(row, "variation_title", "LBL – Nelspruit#{separator}#{option_label}")

      result = %DiscoveryResult{
        events: [TickeraCatalogFixtures.lbl_event()],
        catalog_rows: [row]
      }

      assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

      assert normalized.ticket_type_name == "LBL – Nelspruit [Kaartjie]"
      refute Enum.any?(findings, &(&1.severity == :blocking))
    end
  end

  test "variation product collapses repeated whitespace after prefix stripping" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "variation_title", "LBL – Nelspruit -   Kaartjie   VIP")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == "LBL – Nelspruit [Kaartjie VIP]"
    refute Enum.any?(findings, &(&1.severity == :blocking))
  end

  test "variation product with missing variation title creates a blocking finding" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "variation_title", " ")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [_normalized], findings: findings}} = Normalizer.normalize(result)

    assert Enum.any?(
             findings,
             &(&1.code == :ambiguous_variation_ticket_type_name and &1.severity == :blocking and
                 &1.woo_variation_id == 108_658)
           )
  end

  test "variation product with missing product title creates a blocking finding" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "product_title", nil)

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{rows: [normalized], findings: findings}} = Normalizer.normalize(result)

    assert normalized.ticket_type_name == nil

    assert Enum.any?(
             findings,
             &(&1.code == :ambiguous_variation_ticket_type_name and &1.severity == :blocking and
                 &1.woo_variation_id == 108_658)
           )
  end

  test "variation title equal to product title creates a blocking finding" do
    [row | _rest] = TickeraCatalogFixtures.lbl_variation_rows()
    row = Map.put(row, "variation_title", "LBL – Nelspruit")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [row]
    }

    assert {:ok, %{findings: findings}} = Normalizer.normalize(result)

    assert Enum.any?(
             findings,
             &(&1.code == :ambiguous_variation_ticket_type_name and &1.severity == :blocking)
           )
  end

  test "duplicate variation ticket type names block within the same Tickera event" do
    [first, second] = TickeraCatalogFixtures.lbl_variation_rows()
    second = Map.put(second, "variation_title", "Kaartjie")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.lbl_event()],
      catalog_rows: [first, second]
    }

    assert {:ok, %{findings: findings}} = Normalizer.normalize(result)

    duplicate_findings =
      Enum.filter(
        findings,
        &(&1.code == :duplicate_ticket_type_name and &1.severity == :blocking)
      )

    assert Enum.map(duplicate_findings, & &1.woo_variation_id) == [108_658, 108_659]
  end

  test "duplicate ticket type names across different Tickera events do not block" do
    [first | _rest] = TickeraCatalogFixtures.lbl_variation_rows()

    second =
      first
      |> Map.put("tickera_event_id", 108_001)
      |> Map.put("event_title", "Lynette Beer LIVE - GP")
      |> Map.put("event_slug", "lynette-beer-live-gp")
      |> Map.put("woo_variation_id", 108_660)

    result = %DiscoveryResult{
      events: [
        TickeraCatalogFixtures.lbl_event(),
        TickeraCatalogFixtures.lbl_event()
        |> Map.put("tickera_event_id", 108_001)
        |> Map.put("event_title", "Lynette Beer LIVE - GP")
        |> Map.put("event_slug", "lynette-beer-live-gp")
      ],
      catalog_rows: [first, second]
    }

    assert {:ok, %{findings: findings}} = Normalizer.normalize(result)

    refute Enum.any?(findings, &(&1.code == :duplicate_ticket_type_name))
  end
end
