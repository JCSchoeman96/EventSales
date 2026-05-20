defmodule EventSales.Ingestion.TickeraAttendeeSnapshotsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraAttendeeSnapshot

  alias EventSales.Ingestion.{
    TickeraAttendeeSnapshotHash,
    TickeraAttendeeSnapshots,
    TickeraAttendeeSyncRuns,
    TickeraEventSources
  }

  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("tickera-snapshot-admin@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Snapshot",
        slug: unique_slug("tickera-snapshot")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_SNAPSHOT"
        },
        actor: admin
      )

    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    {:ok, admin: admin, source_system: source_system, event: event, source: source, run: run}
  end

  test "upsert_from_tickera creates and updates normalized attendee snapshot", %{
    source_system: source_system,
    event: event,
    source: source,
    run: run
  } do
    attrs =
      attendee_attrs(source_system, event, source, run, %{
        ticket_code: " ABC123 ",
        checksum: "CHK123",
        first_name: " Jan ",
        last_name: " Smit ",
        email: " JAN@EXAMPLE.COM ",
        buyer_email: " BUYER@EXAMPLE.COM ",
        checked_in?: true,
        transaction_id: "do-not-store",
        custom_fields: %{"Level" => "VIP"}
      })

    assert {:ok, snapshot} = TickeraAttendeeSnapshots.upsert_from_tickera(attrs, internal?: true)

    assert snapshot.ticket_code == "ABC123"
    assert snapshot.first_name == "Jan"
    assert snapshot.email == "jan@example.com"
    assert snapshot.buyer_email == "buyer@example.com"
    assert snapshot.checked_in
    assert snapshot.custom_fields == %{"Level" => "VIP"}

    refute Map.has_key?(snapshot, :transaction_id)

    assert {:ok, updated} =
             TickeraAttendeeSnapshots.upsert_from_tickera(
               Map.merge(attrs, %{first_name: "Piet", raw_source_hash: "hash-updated"}),
               internal?: true
             )

    assert updated.id == snapshot.id
    assert updated.first_name == "Piet"
    assert updated.raw_source_hash == "hash-updated"
    assert Ash.count!(TickeraAttendeeSnapshot, domain: Ingestion) == 1
  end

  test "validations reject missing ticket code, raw hash, and invalid custom fields", %{
    source_system: source_system,
    event: event,
    source: source,
    run: run
  } do
    attrs = attendee_attrs(source_system, event, source, run, %{})

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSnapshots.upsert_from_tickera(Map.put(attrs, :ticket_code, ""),
               internal?: true
             )

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSnapshots.upsert_from_tickera(Map.put(attrs, :raw_source_hash, ""),
               internal?: true
             )

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSnapshots.upsert_from_tickera(Map.put(attrs, :custom_fields, []),
               internal?: true
             )
  end

  test "upsert_from_tickera derives event and source from tickera_event_source", %{
    source_system: source_system,
    event: _event,
    source: source,
    run: run
  } do
    other_event =
      SalesHelpers.create_event!(source_system, %{
        name: "Other Snapshot Event",
        slug: unique_slug("other-snapshot-event")
      })

    other_source_system = SalesHelpers.create_source_system!()

    attrs =
      attendee_attrs(other_source_system, other_event, source, run, %{
        ticket_code: "MISMATCHED"
      })

    assert {:ok, snapshot} =
             TickeraAttendeeSnapshots.upsert_from_tickera(attrs, internal?: true)

    assert snapshot.event_id == source.event_id
    assert snapshot.source_system_id == source.source_system_id
    refute snapshot.event_id == other_event.id
    refute snapshot.source_system_id == other_source_system.id
  end

  test "list and get facades are bounded and ordered", %{
    admin: admin,
    source_system: source_system,
    event: event,
    source: source,
    run: run
  } do
    {:ok, first} =
      TickeraAttendeeSnapshots.upsert_from_tickera(
        attendee_attrs(source_system, event, source, run, %{
          ticket_code: "ONE",
          last_seen_at: ~U[2026-05-01 10:00:00Z]
        }),
        internal?: true
      )

    {:ok, second} =
      TickeraAttendeeSnapshots.upsert_from_tickera(
        attendee_attrs(source_system, event, source, run, %{
          ticket_code: "TWO",
          last_seen_at: ~U[2026-05-01 11:00:00Z]
        }),
        internal?: true
      )

    assert {:ok, [listed_second, listed_first]} =
             TickeraAttendeeSnapshots.list_for_event(event.id, actor: admin, limit: 2)

    assert listed_second.id == second.id
    assert listed_first.id == first.id

    assert {:ok, [listed_source]} =
             TickeraAttendeeSnapshots.list_for_source(source.id, actor: admin, limit: 1)

    assert listed_source.id == second.id

    assert {:ok, found} =
             TickeraAttendeeSnapshots.get_by_ticket_code(source.id, "ONE", actor: admin)

    assert found.id == first.id
  end

  test "direct Ash mutation without authorization context fails", %{
    source_system: source_system,
    event: event,
    source: source,
    run: run
  } do
    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSnapshot
             |> Ash.Changeset.for_create(
               :upsert_from_tickera,
               attendee_attrs(source_system, event, source, run, %{})
             )
             |> Ash.create(domain: Ingestion)
  end

  test "resource attributes omit API key and transaction fields" do
    names =
      TickeraAttendeeSnapshot
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    refute :api_key in names
    refute :tickera_api_key in names
    refute :transaction_id in names
  end

  test "snapshot hash canonicalizes maps and excludes API key fields" do
    left = %{
      ticket_code: "ABC",
      custom_fields: %{"b" => 2, "a" => %{"z" => 1, "y" => 2}},
      list: [1, 2],
      api_key: "secret"
    }

    right = %{
      "custom_fields" => %{"a" => %{"y" => 2, "z" => 1}, "b" => 2},
      "ticket_code" => "ABC",
      "list" => [1, 2],
      "tickera_api_key" => "another-secret"
    }

    different_order = Map.put(right, "list", [2, 1])

    assert TickeraAttendeeSnapshotHash.hash(left) == TickeraAttendeeSnapshotHash.hash(right)

    refute TickeraAttendeeSnapshotHash.hash(right) ==
             TickeraAttendeeSnapshotHash.hash(different_order)

    assert TickeraAttendeeSnapshotHash.hash(%{ticket_code: "ABC"}) =~ ~r/^[0-9a-f]{64}$/
  end

  defp attendee_attrs(source_system, event, source, run, overrides) do
    %{
      tickera_event_source_id: source.id,
      tickera_attendee_sync_run_id: run.id,
      source_system_id: source_system.id,
      event_id: event.id,
      ticket_code: "TICKET-1",
      checksum: "CHECK-1",
      ticket_type_id: 123,
      ticket_type: "General",
      first_name: "Jan",
      last_name: "Smit",
      email: "jan@example.com",
      buyer_first: "Buyer",
      buyer_last: "Person",
      buyer_email: "buyer@example.com",
      allowed_checkins: 1,
      used_checkins: 0,
      remaining_checkins: 1,
      checked_in?: false,
      payment_status: "completed",
      payment_date_raw: "2026-05-01",
      custom_fields: %{},
      raw_source_hash: "hash-1",
      last_seen_at: ~U[2026-05-01 10:00:00Z]
    }
    |> Map.merge(overrides)
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

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
