defmodule EventSales.Ingestion.TickeraReconciliationFindingsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraReconciliationFinding

  alias EventSales.Ingestion.{
    TickeraEventSources,
    TickeraReconciliationFindings,
    TickeraReconciliationRuns
  }

  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("tickera-reconciliation-finding-admin@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Reconciliation Finding",
        slug: unique_slug("tickera-reconciliation-finding")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECONCILIATION_FINDING"
        },
        actor: admin
      )

    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    {:ok, admin: admin, source_system: source_system, event: event, source: source, run: run}
  end

  test "source_scope_key is deterministic for source-backed and no-source findings", %{
    event: event,
    source: source
  } do
    assert TickeraReconciliationFindings.source_scope_key(%{
             event_id: event.id,
             tickera_event_source_id: source.id
           }) == "source:" <> source.id

    assert TickeraReconciliationFindings.source_scope_key(%{
             event_id: event.id,
             tickera_event_source_id: nil
           }) == "no_source:" <> event.id

    refute TickeraReconciliationFindings.source_scope_key(%{
             event_id: event.id,
             tickera_event_source_id: source.id
           }) =~ "%"
  end

  test "upsert_open uses source-scoped identity for source-backed findings", %{
    event: event,
    source: source,
    run: run
  } do
    attrs = finding_attrs(run, source, event, :woo_paid_missing_tickera)

    assert {:ok, first} = TickeraReconciliationFindings.upsert_open(attrs, internal?: true)

    assert {:ok, second} =
             attrs
             |> Map.put(:details, %{changed: true})
             |> TickeraReconciliationFindings.upsert_open(internal?: true)

    assert second.id == first.id
    assert second.details == %{"changed" => true}
    assert Ash.count!(TickeraReconciliationFinding, domain: Ingestion) == 1
  end

  test "no-source findings with the same event and fingerprint upsert into one row", %{
    event: event,
    source_system: source_system,
    run: source_backed_run
  } do
    no_source_run = %{source_backed_run | tickera_event_source_id: nil}

    attrs =
      finding_attrs(no_source_run, nil, event, :no_tickera_source)
      |> Map.put(:source_system_id, source_system.id)

    assert {:ok, first} = TickeraReconciliationFindings.upsert_open(attrs, internal?: true)
    assert first.source_scope_key == "no_source:" <> event.id

    assert {:ok, second} = TickeraReconciliationFindings.upsert_open(attrs, internal?: true)

    assert second.id == first.id
    assert Ash.count!(TickeraReconciliationFinding, domain: Ingestion) == 1
  end

  test "same fingerprint under a different source scope creates a separate row", %{
    admin: admin,
    event: event,
    source: source,
    source_system: source_system,
    run: run
  } do
    other_event =
      SalesHelpers.create_event!(source_system, %{
        name: "Other source event",
        slug: unique_slug("other-source-event")
      })

    {:ok, other_source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: other_event.id,
          api_key_env_var: "TICKERA_API_KEY_OTHER_RECONCILIATION_FINDING"
        },
        actor: admin
      )

    attrs =
      run
      |> finding_attrs(source, event, :woo_paid_missing_tickera)
      |> Map.put(:fingerprint, "same-fingerprint")

    other_attrs =
      attrs
      |> Map.put(:tickera_event_source_id, other_source.id)
      |> Map.put(:source_scope_key, "source:" <> other_source.id)

    assert {:ok, _first} = TickeraReconciliationFindings.upsert_open(attrs, internal?: true)

    assert {:ok, _second} =
             TickeraReconciliationFindings.upsert_open(other_attrs, internal?: true)

    assert Ash.count!(TickeraReconciliationFinding, domain: Ingestion) == 2
  end

  test "resolve ignore and reopen update status fields", %{event: event, source: source, run: run} do
    {:ok, finding} =
      run
      |> finding_attrs(source, event, :woo_paid_missing_tickera)
      |> TickeraReconciliationFindings.upsert_open(internal?: true)

    assert {:ok, resolved} =
             TickeraReconciliationFindings.resolve(
               finding,
               %{resolution_reason: "Checked manually"},
               internal?: true
             )

    assert resolved.status == :resolved
    assert %DateTime{} = resolved.resolved_at
    assert resolved.resolution_reason == "Checked manually"

    assert {:ok, reopened} = TickeraReconciliationFindings.reopen(resolved, internal?: true)
    assert reopened.status == :open
    assert is_nil(reopened.resolved_at)
    assert is_nil(reopened.resolution_reason)

    assert {:ok, ignored} =
             TickeraReconciliationFindings.ignore(
               reopened,
               %{resolution_reason: "Accepted noise"},
               internal?: true
             )

    assert ignored.status == :ignored
    assert ignored.resolution_reason == "Accepted noise"
  end

  defp finding_attrs(run, source, event, type) do
    source_id = if source, do: source.id, else: nil

    source_scope_key =
      TickeraReconciliationFindings.source_scope_key(%{
        event_id: event.id,
        tickera_event_source_id: source_id
      })

    %{
      tickera_reconciliation_run_id: run.id,
      tickera_event_source_id: source_id,
      source_scope_key: source_scope_key,
      source_system_id: run.source_system_id,
      event_id: event.id,
      finding_type: type,
      severity: :critical,
      status: :open,
      details: %{},
      fingerprint:
        TickeraReconciliationFindings.fingerprint([
          "tickera_reconciliation_v1",
          event.id,
          source_scope_key,
          type,
          "aggregate",
          "paid",
          "aggregate",
          "aggregate",
          "none"
        ]),
      first_seen_at: ~U[2026-05-19 10:00:00Z],
      last_seen_at: ~U[2026-05-19 10:00:00Z]
    }
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
