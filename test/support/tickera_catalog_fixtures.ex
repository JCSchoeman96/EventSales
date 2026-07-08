defmodule EventSales.TestSupport.TickeraCatalogFixtures do
  @moduledoc """
  Sanitized Tickera Bridge catalog rows for VS-26A tests.
  """

  @vwg_event %{
    "tickera_event_id" => 109_316,
    "event_title" => "Vroue wat Glo-retreat - PTA",
    "event_slug" => "vroue-wat-glo-retreat-pta",
    "event_status" => "publish",
    "event_source_updated_at" => "2026-06-01T10:00:00Z",
    "event_start_at" => "2026-08-01T16:00:00Z",
    "event_end_at" => "2026-08-01T18:00:00Z",
    "event_location" => "Pretoria",
    "booking_fee_type" => "fixed",
    "booking_fee_value" => "25.00"
  }

  @vwg_row Map.merge(@vwg_event, %{
             "woo_product_id" => 109_740,
             "product_title" => "VWG - Pretoria",
             "product_slug" => "vwg-pretoria",
             "product_status" => "publish",
             "product_source_updated_at" => "2026-06-01T10:05:00Z",
             "ticket_display_name" => "Toegang",
             "price" => "199",
             "regular_price" => "199",
             "ticket_template_id" => "100",
             "woo_variation_id" => nil,
             "variation_title" => nil,
             "variation_status" => nil,
             "variation_source_updated_at" => nil
           })

  def vwg_event, do: Map.new(@vwg_event)
  def vwg_row, do: Map.new(@vwg_row)

  def lbl_event do
    %{
      "tickera_event_id" => 108_000,
      "event_title" => "Lynette Beer LIVE - MP",
      "event_slug" => "lynette-beer-live-mp",
      "event_status" => "publish",
      "event_source_updated_at" => "2026-06-04T10:00:00Z"
    }
  end

  def lbl_variation_rows do
    base =
      lbl_event()
      |> Map.merge(%{
        "woo_product_id" => 108_657,
        "product_title" => "LBL – Nelspruit",
        "product_slug" => "lbl-nelspruit",
        "product_status" => "publish",
        "product_source_updated_at" => "2026-06-04T10:05:00Z",
        "ticket_display_name" => "Toegang",
        "price" => "250",
        "regular_price" => "250",
        "ticket_template_id" => "101"
      })

    [
      Map.merge(base, %{
        "woo_variation_id" => 108_658,
        "variation_title" => "LBL – Nelspruit - Kaartjie",
        "variation_status" => "publish",
        "variation_source_updated_at" => "2026-06-04T10:10:00Z"
      }),
      Map.merge(base, %{
        "woo_variation_id" => 108_659,
        "variation_title" => "LBL – Nelspruit - Kaartjie + 1 x Verloor gewig op jóú manier",
        "variation_status" => "publish",
        "variation_source_updated_at" => "2026-06-04T10:15:00Z"
      })
    ]
  end

  def lynette_wr_event do
    %{
      "tickera_event_id" => 109_120,
      "event_title" => "Lynette Beer LIVE – WR",
      "event_slug" => "lynette-beer-live-wr",
      "event_status" => "publish",
      "event_source_updated_at" => "2026-07-01T10:00:00Z",
      "event_start_at" => "2026-09-01T16:00:00Z",
      "event_end_at" => "2026-09-01T18:00:00Z",
      "event_location" => "Witbank Ridge",
      "booking_fee_type" => "fixed",
      "booking_fee_value" => "25.00"
    }
  end

  def lynette_wr_variation_rows do
    base =
      lynette_wr_event()
      |> Map.merge(%{
        "woo_product_id" => 109_132,
        "product_title" => "Lynette Beer LIVE – WR",
        "product_slug" => "lynette-beer-live-wr",
        "product_status" => "publish",
        "product_source_updated_at" => "2026-07-01T10:05:00Z",
        "ticket_display_name" => "Toegang",
        "price" => "250",
        "regular_price" => "250",
        "ticket_template_id" => "102"
      })

    [
      Map.merge(base, %{
        "woo_variation_id" => 109_165,
        "variation_title" => "Lynette Beer LIVE – WR - Kaartjie",
        "variation_status" => "publish",
        "variation_source_updated_at" => "2026-07-01T10:10:00Z"
      }),
      Map.merge(base, %{
        "woo_variation_id" => 109_167,
        "variation_title" => "Lynette Beer LIVE – WR - VIP",
        "variation_status" => "publish",
        "variation_source_updated_at" => "2026-07-01T10:15:00Z"
      })
    ]
  end

  def private_event_row do
    @vwg_row
    |> Map.merge(%{
      "tickera_event_id" => 200_001,
      "event_title" => "Private Retreat",
      "event_slug" => "private-retreat",
      "event_status" => "private",
      "woo_product_id" => 200_740,
      "product_title" => "Private Ticket",
      "product_slug" => "private-ticket"
    })
  end

  def zero_product_event do
    %{
      "tickera_event_id" => 300_001,
      "event_title" => "Published Empty Event",
      "event_slug" => "published-empty-event",
      "event_status" => "publish",
      "event_source_updated_at" => "2026-06-02T10:00:00Z"
    }
  end

  def variation_rows do
    base =
      @vwg_row
      |> Map.merge(%{
        "tickera_event_id" => 400_001,
        "event_title" => "Variation Event",
        "event_slug" => "variation-event",
        "woo_product_id" => 400_740,
        "product_title" => "Variation Product",
        "product_slug" => "variation-product",
        "ticket_display_name" => nil
      })

    [
      Map.merge(base, %{
        "woo_variation_id" => 400_741,
        "variation_title" => "Early Bird",
        "variation_status" => "publish",
        "variation_source_updated_at" => "2026-06-03T11:00:00Z"
      }),
      Map.merge(base, %{
        "woo_variation_id" => 400_742,
        "variation_title" => "General",
        "variation_status" => "publish",
        "variation_source_updated_at" => "2026-06-03T11:05:00Z"
      })
    ]
  end
end
