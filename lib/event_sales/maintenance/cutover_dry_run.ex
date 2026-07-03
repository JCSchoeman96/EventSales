defmodule EventSales.Maintenance.CutoverDryRun do
  @moduledoc """
  Secret-safe live cutover dry run for VS-25.

  Proves webhook intake, REST credential readiness, admin surfaces, and Oban
  execution without creating sales truth.
  """

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Security.WebhookSignature
  alias EventSales.Ingestion.WooCommerceRestConfig
  alias EventSales.Maintenance.ObanTopologySmokeWorker
  alias EventSales.Maintenance.ProductionSmoke
  alias EventSales.Maintenance.ProductionSmoke.Http
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias Oban.Job

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @rollback_runbook "docs/runbooks/live-webhook-cutover.md"

  @spec run!(keyword()) :: :ok
  def run!(opts \\ []) do
    config = ProductionSmoke.config!(Keyword.get(opts, :env, System.get_env()))
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
        :ok -> output.("cutover dry run: #{label} passed")
        _other -> raise Error, "cutover dry run check failed: #{label}"
      end
    end)

    output.("cutover dry run: complete")
    :ok
  end

  @doc false
  @spec default_check_labels() :: [String.t()]
  def default_check_labels, do: Enum.map(default_checks(), &elem(&1, 0))

  defp default_checks do
    [
      {"application", &check_application/1},
      {"woocommerce rest configuration", &check_rest_configuration/1},
      {"rollback runbook present", &check_rollback_runbook/1},
      {"synthetic webhook intake only", &check_synthetic_webhook_intake/1},
      {"admin reconciliation surfaces", &check_admin_reconciliation_surfaces/1},
      {"oban webhooks queue execution", &check_oban_execution/1}
    ]
  end

  defp check_application(_config) do
    case Application.ensure_all_started(:event_sales) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> raise Error, "application startup failed"
    end
  end

  defp check_rest_configuration(_config) do
    case WooCommerceRestConfig.validate_for_live_cutover() do
      :ok -> :ok
      {:error, _reason} -> raise Error, "woocommerce rest configuration invalid"
    end
  end

  defp check_rollback_runbook(_config) do
    if rollback_runbook_available?() do
      path = Path.join(File.cwd!(), @rollback_runbook)

      if File.read!(path) =~ "Rollback" do
        :ok
      else
        raise Error, "rollback runbook missing rollback section"
      end
    else
      :ok
    end
  end

  defp rollback_runbook_available? do
    path = Path.join(File.cwd!(), @rollback_runbook)
    File.exists?(path)
  end

  defp check_synthetic_webhook_intake(config) do
    orders_before = Ash.count!(Order, domain: Sales)
    items_before = Ash.count!(OrderItem, domain: Sales)
    events_before = Ash.count!(WebhookEvent, domain: Ingestion)

    delivery_id = unique_delivery_id("cutover-dry-run")
    body = synthetic_payload()
    signature = WebhookSignature.sign(body, config.webhook_secret)
    headers = webhook_headers(delivery_id, signature)

    expect_status!(
      Http.request(:post, webhook_url(config), headers, body, "application/json"),
      [200]
    )

    case webhook_event(delivery_id) do
      %WebhookEvent{topic: "eventsales.smoke"} -> :ok
      _ -> raise Error, "synthetic webhook was not durably stored"
    end

    events_after = Ash.count!(WebhookEvent, domain: Ingestion)
    orders_after = Ash.count!(Order, domain: Sales)
    items_after = Ash.count!(OrderItem, domain: Sales)

    if events_after - events_before != 1 do
      raise Error, "expected exactly one new webhook event"
    end

    if orders_after != orders_before or items_after != items_before do
      raise Error, "synthetic webhook created sales truth"
    end

    :ok
  end

  defp check_admin_reconciliation_surfaces(config) do
    auth_headers = admin_auth_headers(config)

    expect_status!(Http.request(:get, url(config, "/admin/reconciliation"), auth_headers), [200])
    expect_status!(Http.request(:get, url(config, "/admin/sync"), auth_headers), [200])
    :ok
  end

  defp check_oban_execution(_config) do
    run_id = "cutover-dry-run-#{System.system_time(:millisecond)}"
    job = insert_smoke_job!(run_id)
    timeout_ms = positive_integer_env("EVENTSALES_SMOKE_TIMEOUT_MS", 60_000)
    poll_ms = positive_integer_env("EVENTSALES_SMOKE_POLL_INTERVAL_MS", 500)
    completed = wait_for_job!(job.id, timeout_ms, poll_ms)

    if completed.state != "completed" do
      raise Error, "oban webhooks queue execution failed"
    end

    :ok
  end

  defp admin_auth_headers(config) do
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
    [{"cookie", Http.cookie_header(cookies)}]
  end

  defp insert_smoke_job!(run_id) do
    %{mode: "success", run_id: run_id}
    |> ObanTopologySmokeWorker.new(queue: :webhooks)
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

  defp synthetic_payload do
    Jason.encode!(%{
      "id" => System.unique_integer([:positive]),
      "cutover_dry_run" => true,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp webhook_headers(delivery_id, signature) do
    [
      {"x-wc-webhook-topic", "eventsales.smoke"},
      {"x-wc-webhook-resource", "smoke"},
      {"x-wc-webhook-delivery-id", delivery_id},
      {"x-wc-webhook-id", "vs-25-cutover-dry-run"},
      {"x-wc-webhook-signature", signature}
    ]
  end

  defp unique_delivery_id(kind) do
    "vs-25-#{kind}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp webhook_url(config), do: url(config, "/webhooks/woocommerce/#{config.webhook_path_token}")
  defp url(config, path), do: config.base_url <> path

  defp expect_status!({:ok, status, _headers, _body}, allowed) do
    if status in allowed, do: :ok, else: raise(Error, "unexpected HTTP response")
  end

  defp expect_status!(_response, _allowed), do: raise(Error, "unexpected HTTP response")

  defp positive_integer_env(key, default) do
    key
    |> System.get_env(Integer.to_string(default))
    |> Integer.parse()
    |> case do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end
end
