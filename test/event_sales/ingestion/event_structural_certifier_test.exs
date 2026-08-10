defmodule EventSales.Ingestion.EventStructuralCertifierTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Ingestion
  alias EventSales.Ingestion.EventStructuralCertifier
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Ingestion.Workers.BackfillOrdersWorker
  alias EventSales.Repo

  test "certifies an exact simple-product structure" do
    source = create_source_system!()

    event =
      create_event!(source, %{
        external_event_id: 70_801,
        external_event_kind: :tickera_event
      })

    ticket =
      create_ticket_type!(event, %{
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 70_801,
        external_product_id: 70_801,
        external_variation_id: nil
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 70_801, woo_variation_id: nil})
    run = ready_run!(source, event, [{70_801, nil}])

    assert {:ok, %{event: certified}} = EventStructuralCertifier.certify(event.id, run.id)
    assert certified.analytics_onboarding_state == :backfill_pending
  end

  test "certifies a product mapping when the optional M2-04 parent mirror is nil" do
    %{source: source, event: event, entries: [%{ticket: ticket}]} =
      structure_fixture!([{70_850, nil}], with_run?: false)

    Repo.query!(
      "UPDATE catalog_ticket_types SET external_product_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(ticket.id)]
    )

    run = ready_run!(source, event, [{70_850, nil}])

    assert {:ok, %{event: certified}} = EventStructuralCertifier.certify(event.id, run.id)
    assert certified.analytics_onboarding_state == :backfill_pending
  end

  test "admin facade delegates structural certification" do
    admin = create_admin!()
    source = create_source_system!()

    event =
      create_event!(source, %{
        external_event_id: 70_802,
        external_event_kind: :tickera_event
      })

    ticket =
      create_ticket_type!(event, %{
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 70_802,
        external_product_id: 70_802
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 70_802})
    run = ready_run!(source, event, [{70_802, nil}])

    assert {:ok, %{event: certified}} =
             TickeraCatalogSync.certify_event_structure(event.id, run.id, actor: admin)

    assert certified.analytics_onboarding_state == :backfill_pending
  end

  test "certifies an exact variation structure" do
    %{event: event, run: run} = structure_fixture!([{70_811, 70_812}])

    assert {:ok, %{event: certified}} = EventStructuralCertifier.certify(event.id, run.id)
    assert certified.analytics_onboarding_state == :backfill_pending
  end

  test "certifies an exact mixed product and variation structure" do
    %{event: event, run: run} = structure_fixture!([{70_813, nil}, {70_814, 70_815}])

    assert {:ok, %{event: certified}} = EventStructuralCertifier.certify(event.id, run.id)
    assert certified.analytics_onboarding_state == :backfill_pending
  end

  test "repeated successful certification is idempotent" do
    %{event: event, run: run} = structure_fixture!([{70_816, nil}])

    assert {:ok, %{event: first}} = EventStructuralCertifier.certify(event.id, run.id)
    assert first.analytics_onboarding_state == :backfill_pending

    assert {:ok, %{event: second}} = EventStructuralCertifier.certify(event.id, run.id)
    assert second.analytics_onboarding_state == :backfill_pending
  end

  test "rejects a run from a foreign SourceSystem" do
    %{event: event} = structure_fixture!([{70_817, nil}])
    foreign = structure_fixture!([{70_818, nil}])

    assert {:error, :run_source_mismatch} =
             EventStructuralCertifier.certify(event.id, foreign.run.id)
  end

  test "rejects a foreign Event scope" do
    %{source: source, event: event} = structure_fixture!([{70_819, nil}], with_run?: false)
    foreign_event_id = event.external_event_id + 1

    foreign_scope_run =
      ready_run!(source, event, [{70_819, nil}], scope_event_id: foreign_event_id)

    assert {:error, :run_scope_mismatch} =
             EventStructuralCertifier.certify(event.id, foreign_scope_run.id)
  end

  test "rejects manual, product-only, variation-only, and whole-store scopes" do
    for scope <- [
          %{"kind" => "manual_rows"},
          %{"kind" => "wordpress_feed", "product_id" => 70_820},
          %{"kind" => "wordpress_feed", "variation_id" => 70_821},
          %{"kind" => "wordpress_feed", "scope" => "whole_store"}
        ] do
      %{source: source, event: event} =
        structure_fixture!([{70_820, nil}], with_run?: false)

      scope = Map.put_new(scope, "event_id", event.external_event_id)
      run = ready_run!(source, event, [{70_820, nil}], scope: scope)

      assert {:error, :run_scope_mismatch} =
               EventStructuralCertifier.certify(event.id, run.id)
    end
  end

  test "rejects a run that is not dry_run_ready" do
    %{source: source, event: event} = structure_fixture!([{70_822, nil}], with_run?: false)
    run = queued_run!(source, event)

    assert {:error, :run_not_ready} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a missing persisted snapshot" do
    %{source: source, event: event} = structure_fixture!([{70_823, nil}], with_run?: false)

    run =
      ready_run!(source, event, [{70_823, nil}],
        plan_snapshot: nil,
        dry_run_hash: nil
      )

    assert {:error, :missing_plan_snapshot} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a snapshot whose canonical hash does not match the run" do
    %{source: source, event: event} = structure_fixture!([{70_824, nil}], with_run?: false)

    run =
      ready_run!(source, event, [{70_824, nil}], dry_run_hash: String.duplicate("0", 64))

    assert {:error, :snapshot_hash_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a snapshot with a blocking discovery finding" do
    %{source: source, event: event} = structure_fixture!([{70_825, nil}], with_run?: false)
    base = snapshot(source.id, [{70_825, nil}])

    blocking_snapshot =
      put_in(base, ["findings"], [
        %{
          "severity" => "blocking",
          "code" => "existing_mapping_conflict",
          "target_type" => "product",
          "target_id" => 70_825,
          "context" => %{}
        }
      ])

    run = ready_run!(source, event, [{70_825, nil}], snapshot: blocking_snapshot)

    assert {:error, :blocking_discovery_findings} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a missing active mapping" do
    %{source: source, event: event} = structure_fixture!([], with_run?: false)
    run = ready_run!(source, event, [{70_826, nil}])

    assert {:error, :missing_mapping} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects an extra active mapping" do
    %{source: source, event: event} =
      structure_fixture!([{70_827, nil}, {70_828, nil}], with_run?: false)

    run = ready_run!(source, event, [{70_827, nil}])

    assert {:error, :extra_mapping} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects an expected source key owned by another Event" do
    source = create_source_system!()

    event =
      create_event!(source, %{external_event_id: 70_829, external_event_kind: :tickera_event})

    foreign_event =
      create_event!(source, %{external_event_id: 70_830, external_event_kind: :tickera_event})

    foreign_ticket =
      create_ticket_type!(foreign_event, %{
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 70_829,
        external_product_id: 70_829
      })

    create_mapping!(source, foreign_event, foreign_ticket, %{woo_product_id: 70_829})
    run = ready_run!(source, event, [{70_829, nil}])

    assert {:error, :foreign_event_mapping} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a missing expected variation" do
    %{source: source, event: event} = structure_fixture!([{70_831, nil}], with_run?: false)
    run = ready_run!(source, event, [{70_831, 70_832}])

    assert {:error, :variation_set_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects an extra active variation" do
    %{source: source, event: event} =
      structure_fixture!([{70_833, 70_834}], with_run?: false)

    run = ready_run!(source, event, [{70_833, nil}])

    assert {:error, :variation_set_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects an inactive expected mapping" do
    %{source: source, event: event} = structure_fixture!([{70_835, nil}], with_run?: false)
    [mapping] = Ash.read!(ProductMapping, domain: Catalog)
    Ash.update!(mapping, %{}, action: :deactivate, domain: Catalog)
    run = ready_run!(source, event, [{70_835, nil}])

    assert {:error, :missing_mapping} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a mapping-bound TicketType on the wrong Event" do
    %{source: source, event: event, entries: [%{mapping: mapping}]} =
      structure_fixture!([{70_836, nil}], with_run?: false)

    foreign_event =
      create_event!(source, %{
        external_event_id: 70_837,
        external_event_kind: :tickera_event
      })

    foreign_ticket =
      create_ticket_type!(foreign_event, %{
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 70_836,
        external_product_id: 70_836
      })

    Repo.query!(
      "UPDATE catalog_product_mappings SET ticket_type_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(foreign_ticket.id), Ecto.UUID.dump!(mapping.id)]
    )

    run = ready_run!(source, event, [{70_836, nil}])

    assert {:error, :ticket_type_event_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects an inactive mapping-bound TicketType" do
    %{source: source, event: event, entries: [%{ticket: ticket}]} =
      structure_fixture!([{70_838, nil}], with_run?: false)

    Ash.update!(ticket, %{active: false}, action: :update, domain: Catalog)
    run = ready_run!(source, event, [{70_838, nil}])

    assert {:error, :ticket_type_inactive} = EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a product TicketType with the wrong canonical identity" do
    %{source: source, event: event, entries: [%{ticket: ticket}]} =
      structure_fixture!([{70_839, nil}], with_run?: false)

    Repo.query!(
      "UPDATE catalog_ticket_types SET external_ticket_type_id = $1 WHERE id = $2",
      [70_840, Ecto.UUID.dump!(ticket.id)]
    )

    run = ready_run!(source, event, [{70_839, nil}])

    assert {:error, :ticket_type_product_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a variation TicketType with the wrong variation identity" do
    %{source: source, event: event, entries: [%{mapping: mapping}]} =
      structure_fixture!([{70_841, 70_842}], with_run?: false)

    wrong_ticket =
      create_ticket_type!(event, %{
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 70_843,
        external_product_id: 70_841,
        external_variation_id: 70_843
      })

    Repo.query!(
      "UPDATE catalog_product_mappings SET ticket_type_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(wrong_ticket.id), Ecto.UUID.dump!(mapping.id)]
    )

    run = ready_run!(source, event, [{70_841, 70_842}])

    assert {:error, :ticket_type_variation_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "rejects a variation TicketType with the wrong parent identity" do
    %{source: source, event: event, entries: [%{ticket: ticket}]} =
      structure_fixture!([{70_844, 70_845}], with_run?: false)

    Repo.query!(
      "UPDATE catalog_ticket_types SET external_product_id = $1 WHERE id = $2",
      [70_846, Ecto.UUID.dump!(ticket.id)]
    )

    run = ready_run!(source, event, [{70_844, 70_845}])

    assert {:error, :ticket_type_product_mismatch} =
             EventStructuralCertifier.certify(event.id, run.id)
  end

  test "names and labels do not affect structural certification" do
    %{source: source, event: event, entries: [%{mapping: mapping, ticket: ticket}]} =
      structure_fixture!([{70_847, nil}], with_run?: false)

    Ash.update!(mapping, %{current_label: "Renamed label"},
      action: :update_current_label,
      domain: Catalog
    )

    Ash.update!(ticket, %{name: "Renamed ticket"}, action: :update, domain: Catalog)
    Ash.update!(event, %{name: "Renamed event"}, action: :update, domain: Catalog)
    run = ready_run!(source, event, [{70_847, nil}])

    assert {:ok, %{event: certified}} = EventStructuralCertifier.certify(event.id, run.id)
    assert certified.analytics_onboarding_state == :backfill_pending
  end

  test "certification writes no historical sales rows or M3 backfill jobs" do
    %{event: event, run: run} = structure_fixture!([{70_848, nil}])
    order_count_before = Repo.query!("SELECT count(*) FROM sales_orders").rows |> hd() |> hd()
    item_count_before = Repo.query!("SELECT count(*) FROM sales_order_items").rows |> hd() |> hd()
    worker = Oban.Worker.to_string(BackfillOrdersWorker)

    job_count_before =
      Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker = $1", [worker]).rows
      |> hd()
      |> hd()

    assert {:ok, _result} = EventStructuralCertifier.certify(event.id, run.id)

    assert Repo.query!("SELECT count(*) FROM sales_orders").rows |> hd() |> hd() ==
             order_count_before

    assert Repo.query!("SELECT count(*) FROM sales_order_items").rows |> hd() |> hd() ==
             item_count_before

    assert Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker = $1", [worker]).rows
           |> hd()
           |> hd() == job_count_before
  end

  test "a structural mutation racing certification cannot leave stale backfill_pending" do
    %{event: event, run: run, entries: [%{mapping: mapping}]} =
      structure_fixture!([{70_849, nil}])

    parent = self()

    certification_task =
      Task.async(fn ->
        EventStructuralCertifier.certify(event.id, run.id,
          after_certification_locks: fn ->
            send(parent, :certifier_event_locked)

            receive do
              :release_certifier -> :ok
            end
          end
        )
      end)

    assert_receive :certifier_event_locked

    mutation_task =
      Task.async(fn ->
        mapping = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
        Ash.update!(mapping, %{}, action: :deactivate, domain: Catalog)
      end)

    send(certification_task.pid, :release_certifier)

    assert {:ok, %{event: certified}} = Task.await(certification_task, 5_000)
    assert certified.analytics_onboarding_state == :backfill_pending
    assert %ProductMapping{active: false} = Task.await(mutation_task, 5_000)

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state == :unverified
  end

  defp create_source_system! do
    Ash.create!(
      SourceSystem,
      %{
        name: "Woo Store",
        kind: :woocommerce,
        base_url: "https://store-#{System.unique_integer([:positive])}.example.test"
      },
      action: :create,
      domain: Catalog
    )
  end

  defp create_admin! do
    user =
      Ash.create!(
        User,
        %{
          email: "structural-certifier-admin-#{System.unique_integer([:positive])}@example.com",
          name: "Structural Certifier Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == ^:admin)
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

  defp create_event!(source, attrs) do
    defaults = %{
      source_system_id: source.id,
      name: "Event",
      slug: "event-#{System.unique_integer([:positive])}",
      status: :active
    }

    Ash.create!(Event, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_ticket_type!(event, attrs) do
    defaults = %{
      event_id: event.id,
      name: "Ticket #{System.unique_integer([:positive])}",
      active: true
    }

    Ash.create!(TicketType, Map.merge(defaults, attrs), action: :create, domain: Catalog)
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

  defp structure_fixture!(product_keys, opts \\ []) do
    source = create_source_system!()

    event =
      create_event!(source, %{
        external_event_id: 71_000 + System.unique_integer([:positive]),
        external_event_kind: :tickera_event
      })

    entries =
      Enum.map(product_keys, fn {product_id, variation_id} = key ->
        ticket_attrs =
          if is_nil(variation_id) do
            %{
              external_ticket_type_kind: :woo_product,
              external_ticket_type_id: product_id,
              external_product_id: product_id,
              external_variation_id: nil
            }
          else
            %{
              external_ticket_type_kind: :woo_variation,
              external_ticket_type_id: variation_id,
              external_product_id: product_id,
              external_variation_id: variation_id
            }
          end

        ticket = create_ticket_type!(event, ticket_attrs)

        mapping =
          create_mapping!(source, event, ticket, %{
            woo_product_id: product_id,
            woo_variation_id: variation_id
          })

        %{key: key, ticket: ticket, mapping: mapping}
      end)

    run =
      if Keyword.get(opts, :with_run?, true) do
        ready_run!(source, event, product_keys)
      end

    %{source: source, event: event, entries: entries, run: run}
  end

  defp queued_run!(source, event, scope \\ nil) do
    scope = scope || %{"kind" => "wordpress_feed", "event_id" => event.external_event_id}

    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source.id,
        scope: scope,
        origin: :human_admin
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp ready_run!(source, event, product_keys, opts \\ []) do
    snapshot = Keyword.get(opts, :snapshot, snapshot(source.id, product_keys))
    {:ok, _bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)

    scope =
      Keyword.get_lazy(opts, :scope, fn ->
        %{
          "kind" => "wordpress_feed",
          "event_id" => Keyword.get(opts, :scope_event_id, event.external_event_id)
        }
      end)

    run = queued_run!(source, event, scope)

    run =
      Ash.update!(
        run,
        %{owner_attempt: 1, owner_max_attempts: 1},
        action: :mark_discovering,
        domain: Ingestion
      )

    Ash.update!(
      run,
      %{
        dry_run_hash: Keyword.get(opts, :dry_run_hash, hash),
        summary: %{},
        plan_snapshot: Keyword.get(opts, :plan_snapshot, snapshot)
      },
      action: :mark_dry_run_ready,
      domain: Ingestion
    )
  end

  defp snapshot(source_system_id, product_keys) do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_system_id,
      "origin" => "human_admin",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [],
      "findings" => [],
      "source_risks" => [],
      "historical_impact" => %{
        "totals" => %{
          "affected_pending_lines" => 0,
          "affected_quantity" => 0,
          "eligible_lines" => 0,
          "eligible_quantity" => 0,
          "deferred_lines" => 0,
          "deferred_quantity" => 0,
          "conflicting_lines" => 0,
          "conflicting_quantity" => 0,
          "already_mapped_lines" => 0,
          "already_mapped_quantity" => 0
        },
        "warning_count" => 0,
        "unresolved_destination_count" => 0,
        "unknown_classification_count" => 0,
        "destinations" => []
      },
      "identity_membership_proof" => %{
        "events" => [],
        "ticket_types" => [],
        "product_mappings" => []
      },
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" =>
          Enum.map(product_keys, fn {product_id, variation_id} ->
            %{"woo_product_id" => product_id, "woo_variation_id" => variation_id}
          end)
      }
    }
  end
end
