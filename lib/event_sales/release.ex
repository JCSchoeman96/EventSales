defmodule EventSales.Release do
  @moduledoc """
  Release helpers for running database migrations with the direct database path
  when it is available.
  """

  @app :event_sales
  @credential_env_key_pattern ~r/(?:password|passwd|secret|token|cookie|(?:^|[_-])key(?:[_-]|$))/i
  @credential_url_env_keys [
    "DATABASE_URL",
    "DIRECT_DATABASE_URL",
    "REDIS_URL",
    "WEBHOOK_RATE_LIMIT_REDIS_URL"
  ]

  @type env_map :: %{optional(String.t()) => String.t() | nil}
  @type release_option ::
          {:env, env_map() | keyword()}
          | {:repos, [module()]}
          | {:with_repo,
             (module(), (module() -> term()) -> {:ok, term(), [atom()]} | {:error, term()})}
          | {:migrator_run, (module(), :up | :down, keyword() -> term())}

  @spec bootstrap(keyword()) :: :ok
  def bootstrap(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())
    start_app = Keyword.get(opts, :start_app, &start_app!/0)

    admin_bootstrap =
      Keyword.get(opts, :admin_bootstrap, fn ->
        EventSales.Maintenance.AdminBootstrap.run!(env)
      end)

    source_bootstrap =
      Keyword.get(opts, :source_bootstrap, fn ->
        EventSales.Maintenance.SourceSystemBootstrap.run!(env)
      end)

    output = Keyword.get(opts, :output, &IO.puts/1)

    with_sanitized_errors(env, fn ->
      start_app.()
      admin_bootstrap.()
      source_bootstrap.()
      output.("production bootstrap: complete")
      :ok
    end)
  end

  @spec migrate_and_bootstrap(keyword()) :: :ok
  def migrate_and_bootstrap(opts \\ []) do
    migrate_fun = Keyword.get(opts, :migrate, &migrate/0)

    migrate_fun.()
    bootstrap(opts)
  end

  @spec migrate([release_option()]) :: [term()]
  def migrate(opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())

    with_sanitized_errors(env, fn ->
      load_app()
      url = fetch_migration_database_url!(env)
      with_repo = Keyword.get(opts, :with_repo, &Ecto.Migrator.with_repo/2)
      migrator_run = Keyword.get(opts, :migrator_run, &Ecto.Migrator.run/3)

      for repo <- Keyword.get(opts, :repos, repos()) do
        with_migration_repo(repo, url, with_repo, fn started_repo ->
          migrator_run.(started_repo, :up, all: true)
        end)
      end
    end)
  end

  @spec rollback(module(), pos_integer(), [release_option()]) :: term()
  def rollback(repo, version, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())

    with_sanitized_errors(env, fn ->
      load_app()
      url = fetch_migration_database_url!(env)
      with_repo = Keyword.get(opts, :with_repo, &Ecto.Migrator.with_repo/2)
      migrator_run = Keyword.get(opts, :migrator_run, &Ecto.Migrator.run/3)

      with_migration_repo(repo, url, with_repo, fn started_repo ->
        migrator_run.(started_repo, :down, to: version)
      end)
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
          #{Exception.format_banner(:error, reason)}
          """
      end
    after
      Application.put_env(app, repo, original_config)
    end
  end

  defp load_app, do: Application.load(@app)

  defp start_app! do
    case Application.ensure_all_started(@app) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        raise "failed to start EventSales for production bootstrap: #{inspect(reason)}"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp with_sanitized_errors(env, fun) do
    fun.()
  rescue
    exception ->
      message =
        exception
        |> Exception.message()
        |> sanitize_message(env)

      reraise RuntimeError.exception(message), __STACKTRACE__
  end

  defp sanitize_message(message, env) do
    message =
      Enum.reduce(credential_values(env), message, fn credential, sanitized ->
        String.replace(sanitized, credential, "[REDACTED]")
      end)

    Regex.replace(~r{((?:ecto|postgres(?:ql)?|redis(?:s)?)://)[^/?#\s]*@}i, message, fn _,
                                                                                        scheme ->
      "#{scheme}[REDACTED]@"
    end)
  end

  defp credential_values(env) do
    env
    |> environment_entries()
    |> Enum.flat_map(fn {name, value} ->
      if credential_env_key?(name), do: [value], else: []
    end)
    |> Kernel.++(url_userinfo_values(env))
    |> Enum.flat_map(&nonempty_values/1)
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp credential_env_key?(name) do
    name = env_name(name)

    name != "EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD" and
      Regex.match?(@credential_env_key_pattern, name)
  end

  defp url_userinfo_values(env) do
    env
    |> environment_entries()
    |> Enum.filter(fn {name, _value} -> env_name(name) in @credential_url_env_keys end)
    |> Enum.flat_map(fn {_name, value} -> uri_userinfo_values(value) end)
  end

  defp uri_userinfo_values(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" ->
        parts = [userinfo | String.split(userinfo, ":", parts: 2)]

        Enum.flat_map(parts, fn part -> [part, decode_uri_component(part)] end)

      _ ->
        []
    end
  rescue
    _exception -> []
  end

  defp uri_userinfo_values(_value), do: []

  defp decode_uri_component(value) do
    URI.decode(value)
  rescue
    _exception -> value
  end

  defp nonempty_values(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [value, trimmed]
    end
  end

  defp nonempty_values(_value), do: []

  defp environment_entries(env) when is_map(env), do: Map.to_list(env)
  defp environment_entries(env) when is_list(env), do: env
  defp environment_entries(_env), do: []

  defp env_name(name) when is_atom(name), do: Atom.to_string(name)
  defp env_name(name) when is_binary(name), do: name
  defp env_name(_name), do: ""
end
