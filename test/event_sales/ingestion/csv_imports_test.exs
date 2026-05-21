defmodule EventSales.Ingestion.CsvImportsTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.CsvImports
  alias EventSales.Ingestion.Resources.{CsvImportBatch, CsvImportRow}
  alias EventSales.Ingestion.Workers.ProcessCsvImportWorker
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("csv-admin@example.com")
    staff = create_user!("csv-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "CSV Facade Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    {:ok, admin: admin, staff: staff, source: source, event: event}
  end

  test "dry_run_file persists batch and rows for an admin", %{admin: admin, event: event} do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "../unsafe/import_valid.csv"},
               actor: admin
             )

    assert batch.status == :dry_run_passed
    assert batch.source_filename == "import_valid.csv"
    assert batch.row_count == 2
    assert batch.valid_count == 2
    assert batch.error_count == 0

    assert {:ok, rows} = CsvImports.list_rows(batch.id, actor: admin)
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.status == :valid))
  end

  test "dry_run_file requires an event scope", %{admin: admin} do
    assert {:error, :event_required} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{source_filename: "x.csv"},
               actor: admin
             )
  end

  test "non-admin actors are denied without side effects", %{staff: staff, event: event} do
    assert {:error, :forbidden} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "x.csv"},
               actor: staff
             )

    assert Ash.count!(CsvImportBatch, domain: Ingestion) == 0
    assert Ash.count!(CsvImportRow, domain: Ingestion) == 0
  end

  test "dry-runs never mutate sales truth across failure modes", %{admin: admin, event: event} do
    for fixture <- [
          "import_valid.csv",
          "import_invalid.csv",
          "import_duplicate_rows.csv",
          "import_unknown_mapping.csv"
        ] do
      before_orders = Ash.count!(Order, domain: Sales)
      before_items = Ash.count!(OrderItem, domain: Sales)

      assert {:ok, _batch} =
               CsvImports.dry_run_file(
                 fixture_path(fixture),
                 %{event_id: event.id, source_filename: fixture},
                 actor: admin
               )

      assert Ash.count!(Order, domain: Sales) == before_orders
      assert Ash.count!(OrderItem, domain: Sales) == before_items
    end
  end

  test "telemetry emits dry-run start and stop without row data", %{admin: admin, event: event} do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach_many(
      "csv-import-test-#{inspect(ref)}",
      [
        EventSales.Telemetry.csv_import_dry_run_start(),
        EventSales.Telemetry.csv_import_dry_run_stop()
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("csv-import-test-#{inspect(ref)}") end)

    assert {:ok, _batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "import_valid.csv"},
               actor: admin
             )

    assert_receive {^ref, [:event_sales, :csv_import, :dry_run, :start], _, start_metadata}

    assert_receive {^ref, [:event_sales, :csv_import, :dry_run, :stop], stop_measurements,
                    stop_metadata}

    assert Map.has_key?(start_metadata, :event_id)
    assert stop_measurements.row_count == 2
    assert stop_metadata.status == :dry_run_passed
    refute Map.has_key?(stop_metadata, :rows)
  end

  test "malformed CSV marks batch failed and emits exception telemetry", %{
    admin: admin,
    event: event
  } do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "csv-import-exception-test-#{inspect(ref)}",
      EventSales.Telemetry.csv_import_dry_run_exception(),
      fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("csv-import-exception-test-#{inspect(ref)}") end)

    before_orders = Ash.count!(Order, domain: Sales)
    before_items = Ash.count!(OrderItem, domain: Sales)

    assert {:ok, batch} =
             CsvImports.dry_run_file(
               malformed_csv_path(),
               %{event_id: event.id, source_filename: "malformed.csv"},
               actor: admin
             )

    assert batch.status == :failed
    assert batch.last_error =~ "invalid_csv"
    assert batch.row_count == 0

    assert_receive {^ref, [:event_sales, :csv_import, :dry_run, :exception], %{count: 1},
                    metadata}

    assert metadata.batch_id == batch.id
    assert metadata.reason =~ "invalid_csv"
    assert Ash.count!(Order, domain: Sales) == before_orders
    assert Ash.count!(OrderItem, domain: Sales) == before_items
  end

  test "queue_apply enqueues CSV apply worker and writes audit for passed dry-run", %{
    admin: admin,
    event: event
  } do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "import_valid.csv"},
               actor: admin
             )

    assert {:ok, %{batch: queued, job: job}} = CsvImports.queue_apply(batch.id, actor: admin)

    assert queued.id == batch.id
    assert job.queue == "csv_imports"

    assert_enqueued(
      worker: ProcessCsvImportWorker,
      queue: :csv_imports,
      args: %{"csv_import_batch_id" => batch.id}
    )

    assert [audit] =
             AuditLog
             |> Ash.Query.filter(event_type == :csv_apply_requested)
             |> Ash.read!(domain: Audit)

    assert audit.actor_type == :user
    assert audit.actor_user_id == admin.id
    assert audit.subject_type == "csv_import_batch"
    assert audit.subject_id == batch.id
    assert audit.event_id == event.id
    assert audit.source == :csv
    assert audit.metadata["result"] == "queued"
    assert audit.metadata["valid_count"] == 2
    refute Map.has_key?(audit.metadata, "rows")
  end

  test "queue_apply rejects non-admins and does not enqueue", %{
    staff: staff,
    admin: admin,
    event: event
  } do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "import_valid.csv"},
               actor: admin
             )

    assert {:error, :forbidden} = CsvImports.queue_apply(batch.id, actor: staff)
    refute_enqueued(worker: ProcessCsvImportWorker)
  end

  test "queue_apply rejects failed and empty batches", %{admin: admin, event: event} do
    assert {:ok, failed} =
             CsvImports.dry_run_file(
               fixture_path("import_invalid.csv"),
               %{event_id: event.id, source_filename: "import_invalid.csv"},
               actor: admin
             )

    assert failed.status == :dry_run_failed
    assert {:error, :invalid_status} = CsvImports.queue_apply(failed.id, actor: admin)

    empty = create_empty_passed_batch!(event, admin)
    assert {:error, :empty_batch} = CsvImports.queue_apply(empty.id, actor: admin)
    refute_enqueued(worker: ProcessCsvImportWorker)
  end

  test "queue_apply does not audit queued result when enqueue fails", %{
    admin: admin,
    event: event
  } do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               fixture_path("import_valid.csv"),
               %{event_id: event.id, source_filename: "import_valid.csv"},
               actor: admin
             )

    assert {:error, {:enqueue_failed, :oban_down}} =
             CsvImports.queue_apply(batch.id,
               actor: admin,
               oban_insert: fn _changeset -> {:error, :oban_down} end
             )

    assert [] =
             AuditLog
             |> Ash.Query.filter(event_type == :csv_apply_requested)
             |> Ash.read!(domain: Audit)

    refute_enqueued(worker: ProcessCsvImportWorker)
  end

  defp fixture_path(name), do: Path.join(["test", "fixtures", "csv", name])

  defp malformed_csv_path do
    path = Path.join(System.tmp_dir!(), "event-sales-imports-#{System.unique_integer()}.csv")
    headers = EventSales.Ingestion.Csv.Parser.required_headers()

    File.write!(path, """
    #{Enum.join(headers, ",")}
    10001,ES-10001,70001,501,2,1000.00,900.00,900.00,completed,ZAR,2026-05-01T08:00:00,2026-05-01T08:05:00
    10002,"ES-10002,70002,501,1,100.00,100.00,100.00,completed,ZAR,2026-05-01T08:00:00,2026-05-01T08:05:00
    """)

    path
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

  defp create_empty_passed_batch!(event, user) do
    batch =
      Ash.create!(
        CsvImportBatch,
        %{
          event_id: event.id,
          uploaded_by_user_id: user.id,
          source_filename: "empty.csv"
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    validating = Ash.update!(batch, %{}, action: :mark_validating, domain: Ingestion)

    Ash.update!(
      validating,
      %{row_count: 0, valid_count: 0, error_count: 0, duplicate_count: 0},
      action: :mark_dry_run_passed,
      domain: Ingestion
    )
  end
end
