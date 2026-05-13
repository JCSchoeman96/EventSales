defmodule EventSales.Release do
  @moduledoc """
  Release helpers for running database migrations with the direct database path
  when it is available.
  """

  @app :event_sales

  @type env_map :: %{optional(String.t()) => String.t() | nil}
  @type release_option ::
          {:env, env_map() | keyword()}
          | {:repos, [module()]}
          | {:with_repo,
             (module(), (module() -> term()) -> {:ok, term(), [atom()]} | {:error, term()})}
          | {:migrator_run, (module(), :up | :down, keyword() -> term())}

  @spec migrate([release_option()]) :: [term()]
  def migrate(opts \\ []) do
    load_app()
    url = fetch_migration_database_url!(Keyword.get(opts, :env, System.get_env()))
    with_repo = Keyword.get(opts, :with_repo, &Ecto.Migrator.with_repo/2)
    migrator_run = Keyword.get(opts, :migrator_run, &Ecto.Migrator.run/3)

    for repo <- Keyword.get(opts, :repos, repos()) do
      with_migration_repo(repo, url, with_repo, fn started_repo ->
        migrator_run.(started_repo, :up, all: true)
      end)
    end
  end

  @spec rollback(module(), pos_integer(), [release_option()]) :: term()
  def rollback(repo, version, opts \\ []) do
    load_app()
    url = fetch_migration_database_url!(Keyword.get(opts, :env, System.get_env()))
    with_repo = Keyword.get(opts, :with_repo, &Ecto.Migrator.with_repo/2)
    migrator_run = Keyword.get(opts, :migrator_run, &Ecto.Migrator.run/3)

    with_migration_repo(repo, url, with_repo, fn started_repo ->
      migrator_run.(started_repo, :down, to: version)
    end)
  end

  @spec migration_database_url(env_map() | keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def migration_database_url(env \\ System.get_env())

  def migration_database_url(env) when is_list(env) do
    env
    |> Map.new()
    |> migration_database_url()
  end

  def migration_database_url(env) when is_map(env) do
    cond do
      present?(Map.get(env, "DIRECT_DATABASE_URL")) ->
        {:ok, Map.fetch!(env, "DIRECT_DATABASE_URL")}

      present?(Map.get(env, "DATABASE_URL")) ->
        {:ok, Map.fetch!(env, "DATABASE_URL")}

      true ->
        {:error,
         "missing DIRECT_DATABASE_URL and DATABASE_URL; set DIRECT_DATABASE_URL for release migrations or fall back to DATABASE_URL only when the pooled runtime path is documented safe"}
    end
  end

  defp fetch_migration_database_url!(env) do
    case migration_database_url(env) do
      {:ok, url} -> url
      {:error, message} -> raise message
    end
  end

  defp with_migration_repo(repo, url, with_repo, fun) do
    app = repo.config()[:otp_app] || @app
    original_config = Application.fetch_env!(app, repo)
    migration_config = Keyword.put(original_config, :url, url)

    Application.put_env(app, repo, migration_config)

    try do
      case with_repo.(repo, fun) do
        {:ok, result, _started_apps} ->
          result

        {:error, reason} ->
          raise """
          failed to start #{inspect(repo)} for release migrations.
          #{sanitize_message(Exception.format_banner(:error, reason))}
          """
      end
    after
      Application.put_env(app, repo, original_config)
    end
  end

  defp load_app, do: Application.load(@app)

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp sanitize_message(message) do
    Regex.replace(~r{((?:ecto|postgres(?:ql)?)://)[^@]+@}i, message, fn _, scheme ->
      "#{scheme}[REDACTED]@"
    end)
  end
end
