defmodule EventSales.ReleaseTest do
  use ExUnit.Case, async: true

  alias EventSales.Release
  alias EventSales.Repo

  describe "migration_database_url/1" do
    test "prefers DIRECT_DATABASE_URL over DATABASE_URL" do
      env = %{
        "DATABASE_URL" => "ecto://pooled-user:pooled-pass@db.internal/event_sales",
        "DIRECT_DATABASE_URL" => "ecto://direct-user:direct-pass@db.internal/event_sales"
      }

      assert {:ok, "ecto://direct-user:direct-pass@db.internal/event_sales"} =
               Release.migration_database_url(env)
    end

    test "falls back to DATABASE_URL when no direct url is present" do
      env = %{"DATABASE_URL" => "ecto://pooled-user:pooled-pass@db.internal/event_sales"}

      assert {:ok, "ecto://pooled-user:pooled-pass@db.internal/event_sales"} =
               Release.migration_database_url(env)
    end

    test "returns a clear error when neither url is present" do
      assert {:error, message} = Release.migration_database_url(%{})

      assert message =~ "DIRECT_DATABASE_URL"
      assert message =~ "DATABASE_URL"
      refute message =~ "ecto://"
    end
  end

  describe "migrate/1" do
    test "uses the direct database url for repo startup and restores the repo config afterwards" do
      env = %{
        "DATABASE_URL" => "ecto://pooled-user:pooled-pass@db.internal/event_sales",
        "DIRECT_DATABASE_URL" => "ecto://direct-user:direct-pass@db.internal/event_sales"
      }

      original_config = Application.fetch_env!(:event_sales, Repo)

      result =
        Release.migrate(
          env: env,
          repos: [Repo],
          with_repo: fn repo, fun ->
            send(
              self(),
              {:repo_config_during_with_repo, Application.fetch_env!(:event_sales, repo)}
            )

            {:ok, fun.(repo), []}
          end,
          migrator_run: fn repo, direction, opts ->
            send(self(), {:migrator_run, repo, direction, opts})
            :migrated
          end
        )

      assert result == [:migrated]

      assert_received {:repo_config_during_with_repo, migration_config}

      assert migration_config[:url] == "ecto://direct-user:direct-pass@db.internal/event_sales"
      assert migration_config[:migration_lock] == :pg_advisory_lock

      assert Keyword.drop(migration_config, [:url]) ==
               Keyword.drop(original_config, [:url])

      assert_received {:migrator_run, Repo, :up, [all: true]}
      assert Application.fetch_env!(:event_sales, Repo) == original_config
    end

    test "redacts credentials when repo startup fails" do
      env = %{
        "DIRECT_DATABASE_URL" => "ecto://direct-user:super-secret@db.internal/event_sales"
      }

      exception =
        assert_raise RuntimeError, fn ->
          Release.migrate(
            env: env,
            repos: [Repo],
            with_repo: fn _repo, _fun ->
              {:error,
               RuntimeError.exception(
                 "failed to connect to ecto://direct-user:super-secret@db.internal/event_sales"
               )}
            end
          )
        end

      assert exception.message =~ "ecto://[REDACTED]@db.internal/event_sales"
      refute exception.message =~ "direct-user:super-secret"
    end
  end

  describe "rollback/3" do
    test "runs rollback through the selected migration url" do
      env = %{
        "DATABASE_URL" => "ecto://pooled-user:pooled-pass@db.internal/event_sales"
      }

      original_config = Application.fetch_env!(:event_sales, Repo)

      result =
        Release.rollback(
          Repo,
          20_260_513_122_000,
          env: env,
          with_repo: fn repo, fun ->
            send(self(), {:rollback_repo_url, Application.fetch_env!(:event_sales, repo)[:url]})
            {:ok, fun.(repo), []}
          end,
          migrator_run: fn repo, direction, opts ->
            send(self(), {:rollback_run, repo, direction, opts})
            :rolled_back
          end
        )

      assert result == :rolled_back

      assert_received {:rollback_repo_url,
                       "ecto://pooled-user:pooled-pass@db.internal/event_sales"}

      assert_received {:rollback_run, Repo, :down, [to: 20_260_513_122_000]}
      assert Application.fetch_env!(:event_sales, Repo) == original_config
    end
  end

  describe "migrate_and_bootstrap/1" do
    test "runs migrations before admin and source bootstraps" do
      caller = self()

      assert :ok =
               Release.migrate_and_bootstrap(
                 migrate: fn -> send(caller, :migrated) end,
                 start_app: fn ->
                   assert_received :migrated
                   send(caller, :started)
                   :ok
                 end,
                 admin_bootstrap: fn ->
                   assert_received :started
                   send(caller, :admin_bootstrapped)
                   %{user_status: :existing, password_rotated?: false}
                 end,
                 source_bootstrap: fn ->
                   assert_received :admin_bootstrapped
                   send(caller, :source_bootstrapped)
                   %{name: "Production WooCommerce", status: :existing}
                 end,
                 output: fn line -> send(caller, {:output, line}) end
               )

      assert_received :source_bootstrapped
      assert_received {:output, "production bootstrap: complete"}
    end

    test "fails without running later steps when migrations fail" do
      assert_raise RuntimeError, "migration failed", fn ->
        Release.migrate_and_bootstrap(
          migrate: fn -> raise "migration failed" end,
          start_app: fn -> flunk("application must not start") end,
          admin_bootstrap: fn -> flunk("admin bootstrap must not run") end,
          source_bootstrap: fn -> flunk("source bootstrap must not run") end
        )
      end
    end
  end

  describe "bootstrap/1" do
    test "does not migrate, bootstraps admin then source, and emits only safe completion output" do
      caller = self()

      assert :ok =
               Release.bootstrap(
                 env: %{},
                 migrate: fn -> flunk("bootstrap must not run migrations") end,
                 start_app: fn ->
                   send(caller, :started)
                   :ok
                 end,
                 admin_bootstrap: fn ->
                   assert_received :started
                   send(caller, :admin_bootstrapped)
                   %{user_status: :created, password: "must not be printed"}
                 end,
                 source_bootstrap: fn ->
                   assert_received :admin_bootstrapped
                   send(caller, :source_bootstrapped)
                   %{name: "Production WooCommerce", secret: "must not be printed"}
                 end,
                 output: fn line -> send(caller, {:output, line}) end
               )

      assert_received :source_bootstrapped
      assert_received {:output, "production bootstrap: complete"}
      refute_received {:output, _line}
    end

    test "admin bootstrap failure prevents source bootstrap and success output" do
      assert_raise RuntimeError, "admin bootstrap failed", fn ->
        Release.bootstrap(
          env: %{},
          start_app: fn -> :ok end,
          admin_bootstrap: fn -> raise "admin bootstrap failed" end,
          source_bootstrap: fn -> flunk("source bootstrap must not run") end,
          output: fn _line -> flunk("success output must not run") end
        )
      end
    end
  end
end
