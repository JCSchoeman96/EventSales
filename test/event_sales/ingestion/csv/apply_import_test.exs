defmodule EventSales.Ingestion.Csv.ApplyImportTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.{DashboardCache, HotStateAggregator}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Csv.ApplyImport
  alias EventSales.Ingestion.CsvImports
  alias EventSales.Ingestion.Resources.{CsvImportBatch, CsvImportRow}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    HotStateAggregator.reset_for_test!()
    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    admin = create_user!("csv-apply-admin@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "CSV Apply Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    {:ok, admin: admin, source: source, event: event, ticket: ticket}
  end

  test "applies valid dry-run rows from persisted row data", %{
    admin: admin,
    event: event
  } do
    test_pid = self()
    handler_id = "csv-apply-stop-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        EventSales.Telemetry.csv_import_apply_stop(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:csv_apply_stop, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "import_valid.csv"},
               actor: admin
             )

    assert :ok = DashboardCache.put_event_summary(event.id, %{total_sold: 0})
    assert {:ok, applied} = ApplyImport.apply(batch.id)
    assert applied.status == :applied
    assert %DateTime{} = applied.applied_at

    assert Enum.map(rows(batch.id), & &1.status) == [:applied, :applied]
    assert Ash.count!(Order, domain: Sales) == 2
    assert Ash.count!(OrderItem, domain: Sales) == 2
    assert {:ok, summary} = DashboardCache.get_event_summary(event.id)
    assert summary.total_sold == 3

    assert Enum.all?(order_items(), fn item ->
             item.event_id == event.id and
               item.item_kind == :ticket and
               item.mapping_status == :mapped
           end)

    assert_receive {:csv_apply_stop, [:event_sales, :csv_import, :apply, :stop], measurements,
                    metadata}

    assert measurements.applied_count == 2
    assert measurements.failed_count == 0
    assert metadata.status == :applied
  end

  test "applied batch is a terminal no-op", %{admin: admin, event: event} do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "import_valid.csv"},
               actor: admin
             )

    assert {:ok, applied} = ApplyImport.apply(batch.id)
    assert {:ok, applied_again} = ApplyImport.apply(batch.id)
    assert applied_again.id == applied.id
    assert applied_again.status == :applied
    assert Ash.count!(Order, domain: Sales) == 2
    assert Ash.count!(OrderItem, domain: Sales) == 2
  end

  test "invalid dry-run status does not apply", %{admin: admin, event: event} do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_invalid.csv"),
               %{event_id: event.id, source_filename: "import_invalid.csv"},
               actor: admin
             )

    assert batch.status == :dry_run_failed
    assert {:error, :invalid_status} = ApplyImport.apply(batch.id)
    assert Ash.count!(Order, domain: Sales) == 0
    assert Ash.count!(OrderItem, domain: Sales) == 0
  end

  test "fails a whole order group when one line cannot be converted", %{
    admin: admin,
    event: event,
    ticket: ticket
  } do
    batch = create_passed_batch!(event, admin, %{row_count: 2, valid_count: 2})

    create_valid_row!(batch, 2, normalized_row(event, ticket, %{"woo_line_item_id" => 80_001}))
    create_valid_row!(batch, 3, normalized_row(event, ticket, %{"woo_line_item_id" => "bad"}))

    assert {:error, _reason} = ApplyImport.apply(batch.id)

    failed_rows = rows(batch.id)
    assert Enum.map(failed_rows, & &1.status) == [:failed, :failed]
    refute Enum.any?(failed_rows, &(&1.status == :applied))
    assert Ash.get!(CsvImportBatch, batch.id, domain: Ingestion).status == :failed
    assert Ash.count!(Order, domain: Sales) == 0
    assert Ash.count!(OrderItem, domain: Sales) == 0
  end

  test "stale no-op fails affected rows instead of marking applied", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    existing =
      SalesHelpers.create_order_from_fixture!(:order_completed, source)

    batch = create_passed_batch!(event, admin, %{row_count: 1, valid_count: 1})

    stale =
      normalized_row(event, ticket, %{
        "woo_order_id" => existing.woo_order_id,
        "order_number" => existing.order_number,
        "woo_line_item_id" => 80_001,
        "updated_at_source" => "2026-05-01T08:00:00"
      })

    create_valid_row!(batch, 2, stale)

    assert {:error, :stale_noop} = ApplyImport.apply(batch.id)
    assert [row] = rows(batch.id)
    assert row.status == :failed
    assert Enum.join(row.error_messages, " ") =~ "stale"
    assert Ash.get!(CsvImportBatch, batch.id, domain: Ingestion).status == :failed
  end

  test "transient row marking failure leaves batch applying and retry does not duplicate", %{
    admin: admin,
    event: event,
    ticket: ticket
  } do
    batch = create_passed_batch!(event, admin, %{row_count: 2, valid_count: 2})

    create_valid_row!(
      batch,
      2,
      normalized_row(event, ticket, %{
        "woo_order_id" => 91_001,
        "order_number" => "CSV-91001",
        "woo_line_item_id" => 80_001
      })
    )

    create_valid_row!(
      batch,
      3,
      normalized_row(event, ticket, %{
        "woo_order_id" => 91_002,
        "order_number" => "CSV-91002",
        "woo_line_item_id" => 80_002,
        "payment_gateway_transaction_id" => "csv-apply-2"
      })
    )

    assert {:error, :row_mark_timeout} =
             ApplyImport.apply(batch.id, row_marker: __MODULE__.FailSecondGroupRowMarker)

    assert Ash.get!(CsvImportBatch, batch.id, domain: Ingestion).status == :applying
    assert Enum.map(rows(batch.id), & &1.status) == [:applied, :valid]
    assert Ash.count!(Order, domain: Sales) == 2
    assert Ash.count!(OrderItem, domain: Sales) == 2

    assert {:ok, applied} = ApplyImport.apply(batch.id)
    assert applied.status == :applied
    assert Enum.map(rows(batch.id), & &1.status) == [:applied, :applied]
    assert Ash.count!(Order, domain: Sales) == 2
    assert Ash.count!(OrderItem, domain: Sales) == 2
  end

  defmodule FailSecondGroupRowMarker do
    @moduledoc false

    def mark_rows_applied([%{row_number: 3}]), do: {:error, :row_mark_timeout}
    def mark_rows_applied(rows), do: ApplyImport.mark_rows_applied(rows)
  end

  defp fixture_path(name), do: Path.join(["test", "fixtures", "csv", name])

  defp rows(batch_id) do
    CsvImportRow
    |> Ash.Query.filter(csv_import_batch_id == ^batch_id)
    |> Ash.Query.sort(row_number: :asc)
    |> Ash.read!(domain: Ingestion)
  end

  defp order_items do
    OrderItem
    |> Ash.Query.sort(woo_line_item_id: :asc)
    |> Ash.read!(domain: Sales)
  end

  defp create_passed_batch!(event, user, counts) do
    batch =
      Ash.create!(
        CsvImportBatch,
        %{event_id: event.id, uploaded_by_user_id: user.id, source_filename: "manual.csv"},
        action: :create_dry_run,
        domain: Ingestion
      )

    validating = Ash.update!(batch, %{}, action: :mark_validating, domain: Ingestion)

    Ash.update!(
      validating,
      %{
        row_count: Map.fetch!(counts, :row_count),
        valid_count: Map.fetch!(counts, :valid_count),
        error_count: 0,
        duplicate_count: 0
      },
      action: :mark_dry_run_passed,
      domain: Ingestion
    )
  end

  defp create_valid_row!(batch, row_number, normalized_data) do
    Ash.create!(
      CsvImportRow,
      %{
        csv_import_batch_id: batch.id,
        row_number: row_number,
        raw_data: %{},
        normalized_data: normalized_data,
        status: :valid,
        external_order_number: normalized_data["order_number"],
        external_line_key:
          "#{normalized_data["woo_order_id"]}:#{normalized_data["woo_line_item_id"]}"
      },
      action: :store_validation_result,
      domain: Ingestion
    )
  end

  defp normalized_row(event, ticket, overrides) do
    Map.merge(
      %{
        "woo_order_id" => 91_001,
        "order_number" => "CSV-91001",
        "woo_line_item_id" => 80_001,
        "woo_product_id" => 501,
        "woo_variation_id" => 601,
        "quantity" => 1,
        "line_subtotal" => "500.00",
        "line_total" => "500.00",
        "line_discount_total" => "0",
        "order_raw_total" => "500.00",
        "order_raw_discount_total" => "0",
        "order_raw_tax_total" => "0",
        "status" => "completed",
        "currency" => "ZAR",
        "created_at_source" => "2026-05-21T09:55:00",
        "updated_at_source" => "2026-05-21T10:00:00",
        "completed_at" => "2026-05-21T10:00:00",
        "name" => "CSV GA",
        "customer_name" => "Synthetic Import",
        "customer_email" => "synthetic.import@example.test",
        "payment_method" => "payfast",
        "payment_method_title" => "Synthetic PayFast",
        "payment_gateway_transaction_id" => "csv-apply-1",
        "event_id" => event.id,
        "ticket_type_id" => ticket.id
      },
      overrides
    )
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end
end
