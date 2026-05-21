defmodule EventSales.Ingestion.Workers.ProcessCsvImportWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.CsvImportBatch
  alias EventSales.Ingestion.Workers.ProcessCsvImportWorker
  alias EventSales.TestSupport.SalesHelpers

  setup do
    original = Application.get_env(:event_sales, :csv_apply_import)

    on_exit(fn ->
      if original do
        Application.put_env(:event_sales, :csv_apply_import, original)
      else
        Application.delete_env(:event_sales, :csv_apply_import)
      end
    end)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "CSV Worker Event"})
    user = create_user!("csv-worker@example.com")

    {:ok, batch: create_passed_batch!(event, user)}
  end

  test "worker options use csv import queue and unique batch args" do
    opts = ProcessCsvImportWorker.__opts__()

    assert Keyword.fetch!(opts, :queue) == :csv_imports
    assert Keyword.fetch!(opts, :max_attempts) == 5
    assert get_in(Keyword.fetch!(opts, :unique), [:keys]) == [:csv_import_batch_id]
  end

  test "invalid and missing args discard" do
    assert :discard = perform_job(ProcessCsvImportWorker, %{})

    assert :discard =
             perform_job(ProcessCsvImportWorker, %{"csv_import_batch_id" => Ecto.UUID.generate()})
  end

  test "passed batch delegates to apply module", %{batch: batch} do
    Application.put_env(:event_sales, :csv_apply_import, __MODULE__.FakeApply)
    batch_id = batch.id

    assert :ok = perform_job(ProcessCsvImportWorker, %{"csv_import_batch_id" => batch.id})
    assert_receive {:apply, ^batch_id}, 500
  end

  test "already applied batch discards", %{batch: batch} do
    applying = Ash.update!(batch, %{}, action: :mark_applying, domain: Ingestion)

    applied =
      Ash.update!(applying, %{applied_at: DateTime.utc_now()},
        action: :mark_applied,
        domain: Ingestion
      )

    assert :discard = perform_job(ProcessCsvImportWorker, %{"csv_import_batch_id" => applied.id})
  end

  defmodule FakeApply do
    @moduledoc false

    def apply(batch_id, _opts \\ []) do
      send(self(), {:apply, batch_id})
      {:ok, %CsvImportBatch{id: batch_id, status: :applied}}
    end
  end

  defp create_passed_batch!(event, user) do
    batch =
      Ash.create!(
        CsvImportBatch,
        %{event_id: event.id, uploaded_by_user_id: user.id, source_filename: "worker.csv"},
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
