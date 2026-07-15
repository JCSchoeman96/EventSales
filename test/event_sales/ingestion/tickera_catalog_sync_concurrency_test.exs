defmodule EventSales.Ingestion.TickeraCatalogSyncConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  test "separate connections race for one source and leave one run and job" do
    {:ok, state} = Agent.start(fn -> %{} end)
    %{admin: admin, source: source} = create_committed_fixture!(state)

    on_exit(fn ->
      cleanup_committed_fixture!(state, source.id, admin.id)
      Agent.stop(state)
    end)

    parent = self()

    winner =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          TickeraCatalogSync.queue_dry_run(
            %{source_system_id: source.id, scope: manual_scope()},
            actor: admin,
            oban_insert: fn job ->
              send(parent, {:winner_holding_transaction, self()})

              receive do
                :commit_winner -> Oban.insert(job)
              end
            end
          )
        end)
      end)

    assert_receive {:winner_holding_transaction, winner_pid}, 5_000

    loser =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          backend_pid = backend_pid!()
          send(parent, {:loser_backend_ready, backend_pid})

          TickeraCatalogSync.queue_dry_run(
            %{source_system_id: source.id, scope: manual_scope()},
            actor: admin
          )
        end)
      end)

    assert_receive {:loser_backend_ready, loser_backend_pid}, 5_000
    assert_backend_waiting_on_lock!(loser_backend_pid)

    send(winner_pid, :commit_winner)

    winner_result = Task.await(winner, 15_000)
    loser_result = Task.await(loser, 15_000)
    results = [winner_result, loser_result]

    assert [{:ok, %{run: run, job: job}}] =
             Enum.filter(results, &match?({:ok, %{run: _, job: _}}, &1))

    assert [{:error, :catalog_sync_already_active}] =
             Enum.filter(results, &(&1 == {:error, :catalog_sync_already_active}))

    assert [persisted_run] =
             with_unboxed_connection(fn ->
               TickeraCatalogSyncRun
               |> Ash.Query.filter(source_system_id == ^source.id)
               |> Ash.read!(domain: Ingestion)
             end)

    assert persisted_run.id == run.id
    assert persisted_run.status == :queued

    assert [persisted_job] =
             with_unboxed_connection(fn ->
               Repo.all(from(job in Oban.Job, where: job.id == ^job.id))
             end)

    assert persisted_job.args == %{"run_id" => run.id}
  end

  defp create_committed_fixture!(state) do
    with_unboxed_connection(fn ->
      suffix = System.unique_integer([:positive])

      admin =
        Ash.create!(
          User,
          %{
            email: "catalog-sync-race-#{suffix}@example.test",
            name: "Catalog Sync Race",
            password: "valid-pass-123",
            password_confirmation: "valid-pass-123"
          },
          action: :register_with_password,
          domain: Accounts
        )

      {role, created_role_id} =
        Role
        |> Ash.Query.filter(name == :admin)
        |> Ash.read_one!(domain: Accounts)
        |> case do
          nil ->
            role = Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
            {role, role.id}

          role ->
            {role, nil}
        end

      Ash.create!(UserRole, %{user_id: admin.id, role_id: role.id},
        action: :create,
        domain: Accounts
      )

      source =
        SalesHelpers.create_source_system!(%{
          name: "Catalog Sync Race #{suffix}",
          base_url: "https://catalog-sync-race-#{suffix}.example.test"
        })

      Agent.update(
        state,
        &Map.merge(&1, %{
          admin_id: admin.id,
          source_id: source.id,
          created_role_id: created_role_id
        })
      )

      %{admin: admin, source: source}
    end)
  end

  defp assert_backend_waiting_on_lock!(backend_pid, attempts \\ 80)

  defp assert_backend_waiting_on_lock!(_backend_pid, 0),
    do: flunk("loser connection never entered a PostgreSQL lock wait")

  defp assert_backend_waiting_on_lock!(backend_pid, attempts) do
    waiting? =
      with_unboxed_connection(fn ->
        %{rows: [[wait_event_type]]} =
          Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])

        wait_event_type == "Lock"
      end)

    if waiting? do
      :ok
    else
      receive do
      after
        25 -> assert_backend_waiting_on_lock!(backend_pid, attempts - 1)
      end
    end
  end

  defp cleanup_committed_fixture!(state, source_id, admin_id) do
    %{created_role_id: created_role_id} = Agent.get(state, & &1)

    with_unboxed_connection(fn ->
      run_ids =
        Repo.all(
          from(run in TickeraCatalogSyncRun,
            where: run.source_system_id == ^source_id,
            select: run.id
          )
        )

      Repo.delete_all(
        from(job in Oban.Job,
          where: fragment("?->>'run_id' = ANY(?)", job.args, ^run_ids)
        )
      )

      Repo.delete_all(from(run in TickeraCatalogSyncRun, where: run.id in ^run_ids))
      Repo.delete_all(from(source in SourceSystem, where: source.id == ^source_id))
      Repo.delete_all(from(user_role in UserRole, where: user_role.user_id == ^admin_id))
      Repo.delete_all(from(user in User, where: user.id == ^admin_id))

      if created_role_id do
        Repo.delete_all(from(role in Role, where: role.id == ^created_role_id))
      end
    end)
  end

  defp with_unboxed_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp manual_scope do
    %{
      "kind" => "manual_rows",
      "events" => [],
      "catalog_rows" => []
    }
  end
end
