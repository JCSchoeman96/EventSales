defmodule EventSales.Ingestion.CsvApplyResourceTest do
  use EventSales.DataCase, async: false

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{CsvImportBatch, CsvImportRow}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "CSV Apply Resource Event"})
    user = create_user!("csv-apply-resource@example.com")
    batch = create_passed_batch!(event, user)

    {:ok, batch: batch}
  end

  test "batch transitions from dry-run passed through applying to applied", %{batch: batch} do
    assert {:ok, applying} = Ash.update(batch, %{}, action: :mark_applying, domain: Ingestion)
    assert applying.status == :applying

    applied_at = ~U[2026-05-21 10:00:00.000000Z]

    assert {:ok, applied} =
             Ash.update(applying, %{applied_at: applied_at},
               action: :mark_applied,
               domain: Ingestion
             )

    assert applied.status == :applied
    assert applied.applied_at == applied_at
  end

  test "batch cannot apply before dry-run passes", %{batch: batch} do
    uploaded =
      Ash.create!(
        CsvImportBatch,
        %{
          event_id: batch.event_id,
          uploaded_by_user_id: batch.uploaded_by_user_id,
          source_filename: "not-ready.csv"
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    assert {:error, _reason} =
             Ash.update(uploaded, %{}, action: :mark_applying, domain: Ingestion)
  end

  test "row apply actions update row status", %{batch: batch} do
    row =
      Ash.create!(
        CsvImportRow,
        %{
          csv_import_batch_id: batch.id,
          row_number: 2,
          raw_data: %{},
          normalized_data: %{},
          status: :valid,
          external_line_key: "1:1"
        },
        action: :store_validation_result,
        domain: Ingestion
      )

    applied_at = ~U[2026-05-21 10:01:00.000000Z]

    assert {:ok, applied} =
             Ash.update(row, %{applied_at: applied_at},
               action: :mark_applied,
               domain: Ingestion
             )

    assert applied.status == :applied
    assert applied.applied_at == applied_at

    failed_row =
      Ash.create!(
        CsvImportRow,
        %{
          csv_import_batch_id: batch.id,
          row_number: 3,
          raw_data: %{},
          normalized_data: %{},
          status: :valid,
          external_line_key: "1:2"
        },
        action: :store_validation_result,
        domain: Ingestion
      )

    assert {:ok, failed} =
             Ash.update(failed_row, %{error_messages: ["stale source update"]},
               action: :mark_failed,
               domain: Ingestion
             )

    assert failed.status == :failed
    assert failed.error_messages == ["stale source update"]
  end

  defp create_passed_batch!(event, user) do
    batch =
      Ash.create!(
        CsvImportBatch,
        %{
          event_id: event.id,
          uploaded_by_user_id: user.id,
          source_filename: "passed.csv"
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    validating = Ash.update!(batch, %{}, action: :mark_validating, domain: Ingestion)

    Ash.update!(
      validating,
      %{row_count: 1, valid_count: 1, error_count: 0, duplicate_count: 0},
      action: :mark_dry_run_passed,
      domain: Ingestion
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
end
