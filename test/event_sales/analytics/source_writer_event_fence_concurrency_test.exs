defmodule EventSales.Analytics.SourceWriterEventFenceConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  require Ash.Query

  alias EventSales.Analytics.EventSnapshotAffectedEvents
  alias EventSales.Analytics.EventSnapshotRefreshFence

  alias EventSales.Analytics.Resources.{
    AnalyticsContributionFact,
    EventAggregateSnapshot,
    EventDimensionAggregateSnapshot,
    EventDimensionPeriodAggregateSnapshot,
    EventPeriodAggregateSnapshot
  }

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Csv.ApplyImport
  alias EventSales.Ingestion.Resources.{CsvImportBatch, CsvImportRow}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.OrderAttributionCorrection
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem, Refund, RefundLine}

  alias EventSales.TestSupport.{
    EventSnapshotRefreshTestSupport,
    FixtureHelpers,
    SalesHelpers,
    UnboxedPostgres
  }

  test "a non-recognized mapped order writer waits for the event refresh fence" do
    fixture = create_mapped_fixture!() |> register_fixture_cleanup!()
    payload = non_recognized_payload(fixture)

    assert_writer_waits_for_event(
      fixture.event.id,
      0,
      fn ->
        OrderUpserter.upsert_order(fixture.source.id, payload,
          snapshot_refresh_scheduler: fn _event_ids -> :ok end
        )
      end,
      fn ->
        order_count!(fixture.source.id, payload["id"])
      end
    )

    source_id = fixture.source.id
    woo_order_id = payload["id"]

    order =
      UnboxedPostgres.with_connection(fn ->
        Order
        |> Ash.Query.filter(source_system_id == ^source_id and woo_order_id == ^woo_order_id)
        |> Ash.read_one!(domain: Sales)
      end)

    assert %Order{status: :pending} = order

    assert [%OrderItem{event_id: event_id, mapping_status: :mapped}] =
             UnboxedPostgres.with_connection(fn -> order_items!(order.id) end)

    assert event_id == fixture.event.id
  end

  test "a status-only mutation of a non-recognized mapped order waits for the event fence" do
    fixture = create_mapped_fixture!() |> register_fixture_cleanup!()
    payload = non_recognized_payload(fixture)

    assert {:ok, order} =
             UnboxedPostgres.with_connection(fn ->
               OrderUpserter.upsert_order(fixture.source.id, payload,
                 snapshot_refresh_scheduler: fn _event_ids -> :ok end
               )
             end)

    updated_payload =
      payload
      |> Map.put("status", "processing")
      |> Map.put("date_modified_gmt", "2026-05-01T09:15:00")

    assert_writer_waits_for_event(
      fixture.event.id,
      :pending,
      fn ->
        OrderUpserter.upsert_order(fixture.source.id, updated_payload,
          snapshot_refresh_scheduler: fn _event_ids -> :ok end
        )
      end,
      fn ->
        order_status!(order.id)
      end
    )

    assert order_status!(order.id) == :processing
  end

  test "missing catalog mapping on a non-recognized order waits for the mapped event fence" do
    fixture = create_pending_mapping_fixture!() |> register_fixture_cleanup!()

    assert_writer_waits_for_event(
      fixture.event.id,
      :pending_mapping_resolution,
      fn ->
        EventSales.Catalog.MissingCatalogResolver.recover_product(
          fixture.source.id,
          501,
          601,
          snapshot_refresh_scheduler: fn _event_ids -> :ok end
        )
      end,
      fn ->
        item_mapping_status!(fixture.item.id)
      end
    )

    assert {:mapped, event_id} = item_mapping!(fixture.item.id)
    assert event_id == fixture.event.id
  end

  test "affected event resolution includes both sides of an attribution move in canonical order" do
    event_a = "00000000-0000-0000-0000-00000000000a"
    event_b = "00000000-0000-0000-0000-00000000000b"

    assert {:ok, [^event_a, ^event_b]} =
             EventSnapshotAffectedEvents.resolve(
               %{order_items: [%{event_id: event_b}]},
               %{order_items: [%{event_id: event_a}]}
             )
  end

  test "CSV apply inherits the OrderUpserter fence for a non-recognized mapped order" do
    fixture = create_mapped_fixture!()
    fixture = create_csv_batch!(fixture) |> register_fixture_cleanup!()

    assert_writer_waits_for_event(
      fixture.event.id,
      0,
      fn ->
        ApplyImport.apply(fixture.batch.id, order_processed_notifier: __MODULE__.NoopCsvNotifier)
      end,
      fn ->
        order_count!(fixture.source.id, 91_001)
      end
    )

    assert order_count!(fixture.source.id, 91_001) == 1
  end

  test "attribution correction waits for both old and new event fences in canonical order" do
    fixture = create_attribution_fixture!() |> register_fixture_cleanup!()
    parent = self()
    event_ids = Enum.sort([fixture.old_event.id, fixture.new_event.id])
    holders = Enum.map(event_ids, &start_session_fence(parent, &1))

    correction =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          backend_pid = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:attribution_writer_backend, backend_pid})

          OrderAttributionCorrection.correct_confirmed_order_113834(
            fixture.source.id,
            "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120",
            actor: fixture.admin,
            snapshot_refresh_scheduler: fn _event_ids -> :ok end
          )
        end)
      end)

    assert_receive {:attribution_writer_backend, writer_backend}, 5_000
    [first_holder, second_holder] = holders
    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(writer_backend)

    send(first_holder.task.pid, :release_refresh_fence)
    assert :ok = Task.await(first_holder.task, 15_000)
    wait_for_blocking_pid!(writer_backend, second_holder.backend_pid)

    send(second_holder.task.pid, :release_refresh_fence)
    assert :ok = Task.await(second_holder.task, 15_000)
    assert {:ok, _correction} = Task.await(correction, 15_000)

    assert {:ok, %OrderItem{event_id: event_id}} =
             UnboxedPostgres.with_connection(fn ->
               Ash.get(OrderItem, fixture.order_item.id, domain: Sales)
             end)

    assert event_id == fixture.new_event.id
  end

  test "a post-fence writer failure rolls back source data and releases the xact fence" do
    fixture = create_mapped_fixture!() |> register_fixture_cleanup!()
    payload = non_recognized_payload(fixture)
    parent = self()

    writer =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          OrderUpserter.upsert_order(fixture.source.id, payload,
            period_projection_invalidator: fn _before_snapshot, _after_snapshot ->
              observer_pid =
                spawn(fn ->
                  result =
                    UnboxedPostgres.with_connection(fn ->
                      backend_pid = EventSnapshotRefreshFence.connection_backend_pid()
                      send(parent, {:rollback_observer_backend, backend_pid})

                      EventSnapshotRefreshFence.with_serial_event_refresh(fixture.event.id, fn ->
                        send(parent, :rollback_observer_acquired)
                        :ok
                      end)
                    end)

                  send(parent, {:rollback_observer_done, result})
                end)

              send(parent, {:period_failure_waiting, self(), observer_pid})

              receive do
                :force_period_failure -> {:error, :forced_post_fence_failure}
              after
                15_000 -> {:error, :period_failure_test_timeout}
              end
            end,
            snapshot_refresh_scheduler: fn _event_ids ->
              flunk("refresh must not enqueue after period invalidation fails")
            end
          )
        end)
      end)

    assert_receive {:period_failure_waiting, writer_pid, _observer_pid}, 5_000
    assert writer_pid == writer.pid
    assert_receive {:rollback_observer_backend, observer_backend}, 5_000
    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(observer_backend)

    send(writer_pid, :force_period_failure)
    assert {:error, :forced_post_fence_failure} = Task.await(writer, 15_000)
    assert_receive :rollback_observer_acquired, 5_000
    assert_receive {:rollback_observer_done, :ok}, 5_000
    assert order_count!(fixture.source.id, payload["id"]) == 0
  end

  defp create_mapped_fixture! do
    UnboxedPostgres.with_exclusive_setup(fn ->
      suffix = System.unique_integer([:positive])
      source = SalesHelpers.create_source_system!(%{name: "Writer fence #{suffix}"})
      event = SalesHelpers.create_event!(source, %{name: "Writer fence event #{suffix}"})

      ticket =
        SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "Writer fence ticket"})

      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 501,
          woo_variation_id: 601,
          original_label: "Writer fence ticket",
          current_label: "Writer fence ticket",
          active: true
        },
        action: :create,
        domain: Catalog
      )

      %{source: source, event: event, ticket: ticket}
    end)
  end

  defp create_attribution_fixture! do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source = SalesHelpers.create_source_system!()

      old_event =
        SalesHelpers.create_event!(source, %{
          name: "Attribution fence source event",
          external_event_id: 108_658,
          external_event_kind: :tickera_event
        })

      old_ticket = SalesHelpers.create_ticket_type!(old_event, %{name: "Source ticket"})

      new_event =
        SalesHelpers.create_event!(source, %{
          name: "Attribution fence target event",
          external_event_id: 109_120,
          external_event_kind: :tickera_event
        })

      new_ticket =
        SalesHelpers.create_ticket_type!(new_event, %{
          name: "Target ticket",
          external_ticket_type_kind: :woo_variation,
          external_ticket_type_id: 109_167,
          external_product_id: 109_132,
          external_variation_id: 109_167
        })

      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: new_event.id,
          ticket_type_id: new_ticket.id,
          woo_product_id: 109_132,
          woo_variation_id: 109_167,
          original_label: "Target ticket",
          current_label: "Target ticket",
          active: true
        },
        action: :create,
        domain: Catalog
      )

      order_attrs =
        :order_completed
        |> SalesHelpers.normalized_order_attrs_from_fixture!(source)
        |> Map.merge(%{
          woo_order_id: 113_834,
          order_number: "113834",
          status: :pending,
          completed_at: nil
        })

      order = Ash.create!(Order, order_attrs, action: :create_normalized, domain: Sales)

      item =
        SalesHelpers.create_order_item_from_line!(
          order,
          %{
            "id" => 113_834_01,
            "product_id" => 109_132,
            "variation_id" => 109_167,
            "name" => "Target ticket",
            "quantity" => 5,
            "subtotal" => "500.00",
            "total" => "500.00",
            "discount_total" => "0"
          },
          %{
            event_id: old_event.id,
            ticket_type_id: old_ticket.id,
            mapping_status: :mapped,
            item_kind: :ticket
          }
        )

      admin = create_admin!()

      %{
        source: source,
        order: order,
        order_item: item,
        old_event: old_event,
        new_event: new_event,
        admin: admin
      }
    end)
  end

  defp create_admin! do
    user =
      Ash.create!(
        User,
        %{
          email: "attribution-fence-#{System.unique_integer([:positive])}@example.test",
          name: "Attribution Fence Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == :admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end

  defp register_fixture_cleanup!(fixture) do
    on_exit(fn -> cleanup_fixture!(fixture) end)
    fixture
  end

  defp cleanup_fixture!(fixture) do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source_id = fixture.source.id
      event_ids = fixture_event_ids(fixture)
      user_id = Map.get(fixture, :admin, Map.get(fixture, :user)) |> then(&if(&1, do: &1.id))

      order_ids =
        Repo.all(
          from(order in Order, where: order.source_system_id == ^source_id, select: order.id)
        )

      item_ids =
        Repo.all(
          from(item in OrderItem,
            where: item.order_id in ^order_ids,
            select: item.id
          )
        )

      batch_query = from(batch in CsvImportBatch, where: batch.event_id in ^event_ids)

      batch_query =
        if user_id do
          from(batch in batch_query, or_where: batch.uploaded_by_user_id == ^user_id)
        else
          batch_query
        end

      batch_ids = Repo.all(from(batch in batch_query, select: batch.id))

      if batch_ids != [] do
        Repo.delete_all(from(row in CsvImportRow, where: row.csv_import_batch_id in ^batch_ids))
        Repo.delete_all(from(batch in CsvImportBatch, where: batch.id in ^batch_ids))
      end

      audit_query =
        from(audit in AuditLog,
          where: audit.event_id in ^event_ids or audit.subject_id in ^item_ids
        )

      audit_query =
        if user_id do
          from(audit in audit_query, or_where: audit.actor_user_id == ^user_id)
        else
          audit_query
        end

      Repo.delete_all(audit_query)

      refund_ids =
        Repo.all(
          from(refund in Refund, where: refund.source_system_id == ^source_id, select: refund.id)
        )

      if refund_ids != [] do
        Repo.delete_all(from(line in RefundLine, where: line.refund_id in ^refund_ids))
        Repo.delete_all(from(refund in Refund, where: refund.id in ^refund_ids))
      end

      Repo.delete_all(from(coupon in CouponSnapshot, where: coupon.order_id in ^order_ids))
      Repo.delete_all(from(fact in AnalyticsContributionFact, where: fact.event_id in ^event_ids))

      Repo.delete_all(
        from(snapshot in EventAggregateSnapshot, where: snapshot.event_id in ^event_ids)
      )

      Repo.delete_all(
        from(snapshot in EventDimensionAggregateSnapshot, where: snapshot.event_id in ^event_ids)
      )

      Repo.delete_all(
        from(snapshot in EventPeriodAggregateSnapshot, where: snapshot.event_id in ^event_ids)
      )

      Repo.delete_all(
        from(snapshot in EventDimensionPeriodAggregateSnapshot,
          where: snapshot.event_id in ^event_ids
        )
      )

      Repo.delete_all(from(item in OrderItem, where: item.order_id in ^order_ids))
      Repo.delete_all(from(order in Order, where: order.id in ^order_ids))

      Repo.delete_all(
        from(mapping in ProductMapping, where: mapping.source_system_id == ^source_id)
      )

      Repo.delete_all(from(ticket in TicketType, where: ticket.event_id in ^event_ids))
      Repo.delete_all(from(event in Event, where: event.id in ^event_ids))

      if user_id do
        Repo.delete_all(from(user_role in UserRole, where: user_role.user_id == ^user_id))
        Repo.delete_all(from(user in User, where: user.id == ^user_id))
      end

      Repo.delete_all(from(source in SourceSystem, where: source.id == ^source_id))
    end)
  end

  defp fixture_event_ids(fixture) do
    [
      Map.get(fixture, :event),
      Map.get(fixture, :old_event),
      Map.get(fixture, :new_event)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.id)
  end

  defp create_pending_mapping_fixture! do
    fixture = create_mapped_fixture!()

    UnboxedPostgres.with_connection(fn ->
      order = SalesHelpers.create_order_from_fixture!(:order_pending, fixture.source)

      line =
        FixtureHelpers.decode_json_fixture!(:woocommerce, :order_pending)
        |> Map.fetch!("line_items")
        |> hd()

      item =
        SalesHelpers.create_order_item_from_line!(order, line, %{
          mapping_status: :pending_mapping_resolution
        })

      Map.merge(fixture, %{order: order, item: item})
    end)
  end

  defp create_csv_batch!(fixture) do
    UnboxedPostgres.with_connection(fn ->
      user =
        Ash.create!(
          User,
          %{
            email: "writer-fence-#{System.unique_integer([:positive])}@example.test",
            name: "Writer Fence CSV",
            password: "valid-pass-123",
            password_confirmation: "valid-pass-123"
          },
          action: :register_with_password,
          domain: Accounts
        )

      batch =
        Ash.create!(
          CsvImportBatch,
          %{
            event_id: fixture.event.id,
            uploaded_by_user_id: user.id,
            source_filename: "writer-fence.csv"
          },
          action: :create_dry_run,
          domain: Ingestion
        )

      validating = Ash.update!(batch, %{}, action: :mark_validating, domain: Ingestion)

      passed =
        Ash.update!(
          validating,
          %{row_count: 1, valid_count: 1, error_count: 0, duplicate_count: 0},
          action: :mark_dry_run_passed,
          domain: Ingestion
        )

      normalized_data = %{
        "woo_order_id" => 91_001,
        "order_number" => "CSV-WRITER-91001",
        "woo_line_item_id" => 81_001,
        "woo_product_id" => 501,
        "woo_variation_id" => 601,
        "quantity" => 1,
        "line_subtotal" => "450.00",
        "line_total" => "450.00",
        "line_discount_total" => "0",
        "order_raw_total" => "450.00",
        "order_raw_discount_total" => "0",
        "order_raw_tax_total" => "0",
        "status" => "pending",
        "currency" => "ZAR",
        "created_at_source" => "2026-05-21T09:55:00",
        "updated_at_source" => "2026-05-21T10:00:00",
        "completed_at" => nil,
        "name" => "CSV Writer Fence Ticket",
        "customer_name" => "Synthetic CSV",
        "customer_email" => "csv.writer@example.test",
        "payment_method" => "payfast",
        "payment_method_title" => "Synthetic PayFast",
        "payment_gateway_transaction_id" => "csv-writer-fence",
        "event_id" => fixture.event.id,
        "ticket_type_id" => fixture.ticket.id
      }

      Ash.create!(
        CsvImportRow,
        %{
          csv_import_batch_id: passed.id,
          row_number: 2,
          raw_data: %{},
          normalized_data: normalized_data,
          status: :valid,
          external_order_number: normalized_data["order_number"],
          external_line_key: "91001:81001"
        },
        action: :store_validation_result,
        domain: Ingestion
      )

      Map.merge(fixture, %{batch: passed, user: user})
    end)
  end

  defp non_recognized_payload(%{event: _event}) do
    FixtureHelpers.decode_json_fixture!(:woocommerce, :order_pending)
    |> Map.put("id", System.unique_integer([:positive]))
    |> Map.put("number", "WRITER-#{System.unique_integer([:positive])}")
  end

  defp start_session_fence(parent, event_id) do
    task =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
            send(
              parent,
              {:held_event_fence, event_id, self(),
               EventSnapshotRefreshFence.connection_backend_pid()}
            )

            receive do
              :release_refresh_fence -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive {:held_event_fence, ^event_id, _holder_pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid, event_id: event_id}
  end

  defp wait_for_blocking_pid!(waiter_backend, blocker_backend, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait =
      Stream.repeatedly(fn ->
        Process.sleep(15)

        UnboxedPostgres.with_connection(fn ->
          %{rows: [[blocked_by_target?]]} =
            Repo.query!(
              "SELECT $2 = ANY(pg_blocking_pids($1))",
              [waiter_backend, blocker_backend]
            )

          blocked_by_target?
        end)
      end)
      |> Enum.reduce_while(false, fn blocked_by_target?, _ ->
        cond do
          blocked_by_target? -> {:halt, true}
          System.monotonic_time(:millisecond) > deadline -> {:halt, false}
          true -> {:cont, false}
        end
      end)

    unless wait do
      raise "expected backend #{waiter_backend} to block on backend #{blocker_backend}"
    end

    :ok
  end

  defp assert_writer_waits_for_event(
         event_id,
         expected_pre_commit_value,
         writer,
         pre_commit_value
       ) do
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
            send(
              parent,
              {:refresh_fence_held, EventSnapshotRefreshFence.connection_backend_pid()}
            )

            receive do
              :release_refresh_fence -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive {:refresh_fence_held, _holder_backend}, 5_000

    task =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          backend_pid = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:writer_backend, backend_pid})
          writer.()
        end)
      end)

    assert_receive {:writer_backend, writer_backend}, 5_000
    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(writer_backend)
    assert pre_commit_value.() == expected_pre_commit_value

    send(holder.pid, :release_refresh_fence)
    assert {:ok, _result} = Task.await(task, 15_000)
    assert :ok = Task.await(holder, 15_000)
  end

  defp order_count!(source_id, woo_order_id) do
    UnboxedPostgres.with_connection(fn ->
      Repo.one!(
        from(order in Order,
          where: order.source_system_id == ^source_id and order.woo_order_id == ^woo_order_id,
          select: count(order.id)
        )
      )
    end)
  end

  defp order_status!(order_id) do
    UnboxedPostgres.with_connection(fn ->
      case Ash.get(Order, order_id, domain: Sales) do
        {:ok, %Order{status: status}} -> status
        other -> other
      end
    end)
  end

  defp item_mapping_status!(item_id) do
    UnboxedPostgres.with_connection(fn ->
      case Ash.get(OrderItem, item_id, domain: Sales) do
        {:ok, %OrderItem{mapping_status: status}} -> status
        other -> other
      end
    end)
  end

  defp item_mapping!(item_id) do
    UnboxedPostgres.with_connection(fn ->
      case Ash.get(OrderItem, item_id, domain: Sales) do
        {:ok, %OrderItem{mapping_status: status, event_id: event_id}} -> {status, event_id}
        other -> other
      end
    end)
  end

  defmodule NoopCsvNotifier do
    @moduledoc false

    def finalize_csv_import_hot_state(_batch, _event_id, _attempt_token, _opts), do: :ok
  end

  defp order_items!(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
  end
end
