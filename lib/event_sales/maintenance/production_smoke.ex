defmodule EventSales.Maintenance.ProductionSmoke do
  @moduledoc """
  Runs a bounded, secret-safe production smoke test against a deployed EventSales release.
  """

  require Ash.Query

  alias EventSales.Analytics.SnapshotStore.RedixAdapter
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Security.WebhookSignature
  alias EventSales.Maintenance.ObanTopologySmokeWorker
  alias EventSales.Maintenance.ProductionSmoke.Http
  alias EventSales.Repo
  alias Oban.Job

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @required_env %{
    admin_email: "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL",
    admin_password: "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD",
    webhook_path_token: "WEBHOOK_PATH_TOKEN",
    webhook_secret: "WOOCOMMERCE_WEBHOOK_SECRET"
  }

  @spec config!(map() | keyword()) :: map()
  def config!(env \\ System.get_env()) do
    env = Map.new(env)

    config =
      Enum.reduce(@required_env, %{}, fn {field, key}, acc ->
        Map.put(acc, field, required_env!(env, key))
      end)

    Map.put(config, :base_url, base_url!(env))
  end

  @spec run!(keyword()) :: :ok
  def run!(opts \\ []) do
    config = config!(Keyword.get(opts, :env, System.get_env()))
    checks = Keyword.get(opts, :checks, default_checks())
    output = Keyword.get(opts, :output, &IO.puts/1)

    Enum.each(checks, fn {label, check} ->
      result =
        try do
          check.(config)
        rescue
          _error -> :error
        catch
          _kind, _reason -> :error
        end

      case result do
        :ok -> output.("production smoke: #{label} passed")
        _other -> raise Error, "production smoke check failed: #{label}"
      end
    end)

    output.("production smoke: complete")
    :ok
  end

  defp default_checks do
    [
      {"application", &check_application/1},
      {"migrations", &check_migrations/1},
      {"postgres", &check_postgres/1},
      {"redis", &check_redis/1},
      {"oban", &check_oban/1},
      {"health", &check_health/1},
      {"oban protection", &check_oban_protection/1},
      {"invalid webhook", &check_invalid_webhook/1},
      {"valid webhook storage", &check_valid_webhook/1},
      {"admin dashboard and Oban Web", &check_admin_surfaces/1}
    ]
  end

  defp check_application(_config) do
    case Application.ensure_all_started(:event_sales) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> raise Error, "application startup failed"
    end
  end

  defp check_migrations(_config) do
    case Enum.reject(Ecto.Migrator.migrations(Repo), &match?({:up, _, _}, &1)) do
      [] -> :ok
      _pending -> raise Error, "pending migrations"
    end
  end

  defp check_postgres(_config) do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> :ok
      {:error, _reason} -> raise Error, "PostgreSQL unavailable"
    end
  end

  defp check_redis(_config) do
    case Redix.command(RedixAdapter.redix_name(), ["PING"]) do
      {:ok, "PONG"} -> :ok
      _other -> raise Error, "Redis unavailable"
    end
  end

  defp check_oban(_config) do
    run_id = "slice-24-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    success = insert_smoke_job!("success", run_id)
    retry = insert_smoke_job!("fail_once", run_id)
    timeout_ms = positive_integer_env("EVENTSALES_SMOKE_TIMEOUT_MS", 60_000)
    poll_ms = positive_integer_env("EVENTSALES_SMOKE_POLL_INTERVAL_MS", 500)

    success = wait_for_job!(success.id, timeout_ms, poll_ms)
    retry = wait_for_job!(retry.id, timeout_ms, poll_ms)

    if success.state != "completed" or retry.state != "completed" or retry.attempt < 2 or
         Enum.empty?(retry.errors || []) do
      raise Error, "Oban execution proof failed"
    end

    :ok
  end

  defp check_health(config) do
    expect_status!(Http.request(:get, url(config, "/health")), [200])
  end

  defp check_oban_protection(config) do
    expect_status!(Http.request(:get, url(config, "/admin/oban")), [401])
  end

  defp check_invalid_webhook(config) do
    delivery_id = unique_delivery_id("invalid")
    body = smoke_payload()

    headers = webhook_headers(delivery_id, "invalid-signature")

    expect_status!(Http.request(:post, webhook_url(config), headers, body, "application/json"), [
      401
    ])

    if webhook_event(delivery_id), do: raise(Error, "invalid webhook was stored")
    :ok
  end

  defp check_valid_webhook(config) do
    delivery_id = unique_delivery_id("valid")
    body = smoke_payload()
    signature = WebhookSignature.sign(body, config.webhook_secret)

    headers = webhook_headers(delivery_id, signature)

    expect_status!(Http.request(:post, webhook_url(config), headers, body, "application/json"), [
      200
    ])

    case webhook_event(delivery_id) do
      %WebhookEvent{source_system_id: source_system_id} when not is_nil(source_system_id) -> :ok
      _ -> raise Error, "valid webhook was not durably stored"
    end
  end

  defp check_admin_surfaces(config) do
    {:ok, 200, login_headers, login_body} = Http.request(:get, url(config, "/admin/login"))
    csrf_token = Http.csrf_token!(login_body)
    cookies = Http.merge_cookies(%{}, login_headers)

    form =
      URI.encode_query(%{
        "_csrf_token" => csrf_token,
        "admin_session[email]" => config.admin_email,
        "admin_session[password]" => config.admin_password
      })

    headers = [{"cookie", Http.cookie_header(cookies)}]

    {:ok, login_status, response_headers, _body} =
      Http.request(
        :post,
        url(config, "/admin/login"),
        headers,
        form,
        "application/x-www-form-urlencoded"
      )

    unless login_status in [200, 302, 303], do: raise(Error, "admin login failed")

    cookies = Http.merge_cookies(cookies, response_headers)
    auth_headers = [{"cookie", Http.cookie_header(cookies)}]
    expect_status!(Http.request(:get, url(config, "/admin/dashboard"), auth_headers), [200])
    expect_status!(Http.request(:get, url(config, "/admin/oban"), auth_headers), [200, 302])
  end

  defp insert_smoke_job!(mode, run_id) do
    %{mode: mode, run_id: run_id}
    |> ObanTopologySmokeWorker.new()
    |> Oban.insert!()
  end

  defp wait_for_job!(job_id, timeout_ms, poll_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_job!(job_id, deadline, poll_ms)
  end

  defp do_wait_for_job!(job_id, deadline, poll_ms) do
    job = Repo.get!(Job, job_id)

    cond do
      job.state == "completed" ->
        job

      System.monotonic_time(:millisecond) >= deadline ->
        raise Error, "Oban job timeout"

      true ->
        Process.sleep(poll_ms)
        do_wait_for_job!(job_id, deadline, poll_ms)
    end
  end

  defp webhook_event(delivery_id) do
    WebhookEvent
    |> Ash.Query.filter(delivery_id == ^delivery_id)
    |> Ash.read_one!(domain: Ingestion)
  end

  defp smoke_payload do
    Jason.encode!(%{
      "id" => System.unique_integer([:positive]),
      "smoke_test" => true,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp webhook_headers(delivery_id, signature) do
    [
      {"x-wc-webhook-topic", "eventsales.smoke"},
      {"x-wc-webhook-resource", "smoke"},
      {"x-wc-webhook-delivery-id", delivery_id},
      {"x-wc-webhook-id", "slice-24-smoke"},
      {"x-wc-webhook-signature", signature}
    ]
  end

  defp unique_delivery_id(kind) do
    "slice-24-#{kind}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp webhook_url(config), do: url(config, "/webhooks/woocommerce/#{config.webhook_path_token}")
  defp url(config, path), do: config.base_url <> path

  defp expect_status!({:ok, status, _headers, _body}, allowed) do
    if status in allowed, do: :ok, else: raise(Error, "unexpected HTTP response")
  end

  defp expect_status!(_response, _allowed), do: raise(Error, "unexpected HTTP response")

  defp base_url!(env) do
    value =
      case present_value(env, "EVENTSALES_PUBLIC_BASE_URL") do
        nil -> "https://#{required_env!(env, "RAILWAY_PUBLIC_DOMAIN")}"
        explicit -> explicit
      end

    value = String.trim_trailing(value, "/")
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      value
    else
      raise Error, "EVENTSALES_PUBLIC_BASE_URL must be an HTTPS URL"
    end
  end

  defp required_env!(env, key) do
    case present_value(env, key) do
      nil -> raise Error, "production smoke requires #{key}"
      value -> value
    end
  end

  defp present_value(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      _ ->
        nil
    end
  end

  defp positive_integer_env(key, default) do
    key
    |> System.get_env(Integer.to_string(default))
    |> Integer.parse()
    |> case do
      {value, ""} when value > 0 -> value
      _ -> raise Error, "#{key} must be a positive integer"
    end
  end
end
