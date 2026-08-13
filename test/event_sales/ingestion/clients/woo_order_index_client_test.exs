defmodule EventSales.Ingestion.Clients.WooOrderIndexClientTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.Clients.WooOrderIndexClient
  alias EventSales.Ingestion.Clients.WooOrderIndexError

  @source_system_id "550e8400-e29b-41d4-a716-446655440000"
  @start "2026-08-01T00:00:00Z"
  @cutoff "2026-08-12T00:00:00Z"
  @path "/wp-json/eventsales/v1/woo-order-index/manifests"
  @timestamp 1_780_000_000

  defmodule FakeTransport do
    @behaviour EventSales.Ingestion.Clients.WooCommerceTransport

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)
    end

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = List.first(state.responses) || {:error, :missing_response}
        rest = if state.responses == [], do: [], else: tl(state.responses)
        request = %{method: method, url: url, headers: headers, body: body, opts: opts}

        {response, %{state | responses: rest, requests: [request | state.requests]}}
      end)
      |> case do
        {:raise, message} -> raise message
        {:throw, value} -> throw(value)
        {:exit, reason} -> exit(reason)
        response -> response
      end
    end
  end

  setup do
    start_supervised!(FakeTransport)

    original_config = Application.get_env(:event_sales, :woo_order_index)
    original_env = Application.get_env(:event_sales, :env)

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(:event_sales, :woo_order_index,
      base_url: "https://wordpress.example.test/",
      key_id: "order-index-key-1",
      secret: "order-index-secret",
      timeout_ms: 7_000,
      transport: FakeTransport,
      clock: fn -> @timestamp end
    )

    on_exit(fn ->
      restore_env(:woo_order_index, original_config)
      restore_env(:env, original_env)
    end)

    :ok
  end

  test "reproduces the independent PHP HMAC vector exactly" do
    body =
      ~s({"source_system":"wordpress_woo:localhost","backfill_start":"2026-08-01T00:00:00Z","backfill_cutoff":"2026-08-12T00:00:00Z","limit":100})

    assert WooOrderIndexClient.canonical_query_string(%{"z" => "9", "alpha" => "one two"}) ==
             "alpha=one%20two&z=9"

    assert WooOrderIndexClient.canonical_signature_input(
             "post",
             @path,
             "alpha=one%20two&z=9",
             body,
             Integer.to_string(@timestamp),
             "order-index-key-1"
           ) ==
             "POST\n" <>
               @path <>
               "\nquery=alpha=one%20two&z=9\n" <>
               "body_sha256=2aaae8b2e3403ab5cf257b5d896ce70ad63efc2ee587ac1b001e33ac6edadaa5\n" <>
               "timestamp=1780000000\nkey_id=order-index-key-1"

    assert WooOrderIndexClient.signature(
             "post",
             @path,
             "alpha=one%20two&z=9",
             body,
             Integer.to_string(@timestamp),
             "order-index-key-1",
             "order-index-secret"
           ) ==
             "v1=743dcfc3c5f3366fef7df243aacdf7c5740629e6a0313fabbbaf3b2c79670f08"
  end

  test "signing uses uppercase method and the empty GET body hash" do
    input =
      WooOrderIndexClient.canonical_signature_input(
        "get",
        @path <> "/token",
        "cursor=opaque",
        "",
        Integer.to_string(@timestamp),
        "key"
      )

    assert input =~ "GET\n" <> @path <> "/token\n"
    assert input =~ "body_sha256=" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
    assert input =~ "\nkey_id=key"
  end

  test "create_manifest sends exact source-bound JSON once with independent HMAC headers" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page(has_more: true))}])

    assert {:ok, page} =
             WooOrderIndexClient.create_manifest(
               @source_system_id,
               @start,
               @cutoff,
               100
             )

    assert page.boundary_token == "manifest-token"
    assert page.has_more

    assert [request] = FakeTransport.requests()
    assert request.method == :post
    assert request.url == "https://wordpress.example.test" <> @path

    assert request.body ==
             ~s({"source_system":"550e8400-e29b-41d4-a716-446655440000","backfill_start":"2026-08-01T00:00:00Z","backfill_cutoff":"2026-08-12T00:00:00Z","limit":100})

    assert request.opts == [timeout_ms: 7_000]

    assert List.keyfind(request.headers, "content-type", 0) ==
             {"content-type", "application/json"}

    assert List.keyfind(request.headers, "accept", 0) == {"accept", "application/json"}
    assert List.keyfind(request.headers, "authorization", 0) == nil

    assert List.keyfind(request.headers, "x-eventsales-key-id", 0) ==
             {"x-eventsales-key-id", "order-index-key-1"}

    assert List.keyfind(request.headers, "x-eventsales-timestamp", 0) ==
             {"x-eventsales-timestamp", Integer.to_string(@timestamp)}

    assert List.keyfind(request.headers, "x-eventsales-signature", 0) ==
             {"x-eventsales-signature",
              WooOrderIndexClient.signature(
                "POST",
                @path,
                "",
                request.body,
                Integer.to_string(@timestamp),
                "order-index-key-1",
                "order-index-secret"
              )}
  end

  test "create_manifest places the canonical UUID returned by Ecto on the wire" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page())}])

    uppercase_source_system_id = String.upcase(@source_system_id)

    assert {:ok, _page} =
             WooOrderIndexClient.create_manifest(
               uppercase_source_system_id,
               @start,
               @cutoff
             )

    assert [request] = FakeTransport.requests()
    assert Jason.decode!(request.body)["source_system"] == @source_system_id
  end

  test "create_manifest accepts only limits 1 through 100" do
    for limit <- [1, 100] do
      FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page())}])

      assert {:ok, _page} =
               WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff, limit)
    end

    assert length(FakeTransport.requests()) == 1
  end

  test "create_manifest rejects invalid UUID, bounds, and limit before transport" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page())}])

    for args <- [
          {"not-a-uuid", @start, @cutoff, 100},
          {@source_system_id, "2026-08-01", @cutoff, 100},
          {@source_system_id, @start, "2026-08-12T00:00:00+00:00", 100},
          {@source_system_id, @cutoff, @start, 100},
          {@source_system_id, @start, @cutoff, 0},
          {@source_system_id, @start, @cutoff, 101}
        ] do
      assert_error(
        WooOrderIndexClient.create_manifest(
          elem(args, 0),
          elem(args, 1),
          elem(args, 2),
          elem(args, 3)
        ),
        :invalid_request
      )
    end

    assert [] = FakeTransport.requests()
  end

  test "missing order-index config fails closed without Woo credential fallback" do
    Application.put_env(:event_sales, :woo_order_index,
      base_url: "https://wordpress.example.test",
      consumer_key: "woo-consumer-key",
      consumer_secret: "woo-consumer-secret",
      transport: FakeTransport
    )

    assert_error(
      WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff),
      :misconfigured
    )

    assert [] = FakeTransport.requests()
  end

  test "fetch config failures return the bounded misconfigured error" do
    Application.put_env(:event_sales, :woo_order_index,
      base_url: "https://wordpress.example.test",
      transport: FakeTransport
    )

    assert_error(
      WooOrderIndexClient.fetch_manifest_page("manifest-token"),
      :misconfigured
    )

    assert [] = FakeTransport.requests()
  end

  test "production HTTP order-index endpoint is rejected before transport" do
    Application.put_env(:event_sales, :env, :prod)

    Application.put_env(:event_sales, :woo_order_index,
      base_url: "http://wordpress.example.test",
      key_id: "order-index-key-1",
      secret: "order-index-secret",
      transport: FakeTransport
    )

    assert_error(
      WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff),
      :misconfigured
    )

    assert [] = FakeTransport.requests()
  end

  test "POST timeout and transport failures become ambiguous_create without retry" do
    for failure <- [{:error, :timeout}, {:error, :econnreset}] do
      FakeTransport.reset!([failure, {:ok, 200, [], Jason.encode!(valid_page())}])

      assert_error(
        WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff),
        :ambiguous_create
      )

      assert length(FakeTransport.requests()) == 1
    end
  end

  test "malformed successful POST responses are ambiguous and are never retried" do
    for body <- ["not json", Jason.encode!(Map.put(valid_page(), "unexpected", true))] do
      FakeTransport.reset!([{:ok, 200, [], body}, {:ok, 200, [], Jason.encode!(valid_page())}])

      assert_error(
        WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff),
        :ambiguous_create
      )

      assert length(FakeTransport.requests()) == 1
    end
  end

  test "canonical server errors map to bounded reasons" do
    cases = [
      {400, :invalid_request},
      {401, :unauthorized},
      {409, :busy},
      {410, :manifest_expired},
      {404, :manifest_not_found},
      {503, :capture_budget_exceeded},
      {503, :manifest_storage_failed},
      {500, :server_error}
    ]

    for {status, reason} <- cases do
      error_body =
        if status == 503 and reason != :server_error,
          do: Jason.encode!(%{"error" => reason}),
          else: "{}"

      FakeTransport.reset!([{:ok, status, [], error_body}])

      assert_error(
        WooOrderIndexClient.fetch_manifest_page("manifest-token"),
        reason
      )
    end
  end

  test "POST maps canonical errors separately and treats unknown status as ambiguous" do
    for {status, reason, body} <- [
          {404, :manifest_unavailable, "{}"},
          {503, :source_authority_changed,
           Jason.encode!(%{"error" => "source_authority_changed"})},
          {503, :capture_budget_exceeded, Jason.encode!(%{"error" => "capture_budget_exceeded"})},
          {302, :ambiguous_create, "redirect"}
        ] do
      FakeTransport.reset!([{:ok, status, [], body}, {:ok, 200, [], Jason.encode!(valid_page())}])

      assert_error(
        WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff),
        reason
      )

      assert length(FakeTransport.requests()) == 1
    end
  end

  test "unknown POST server outcomes are ambiguous and never retried" do
    cases = [
      {500, Jason.encode!(%{"error" => "upstream_failed"})},
      {502, "Bad Gateway"},
      {503, Jason.encode!(%{"error" => "unknown_source_error"})},
      {503, "not json"},
      {504, "Gateway Timeout"}
    ]

    for {status, body} <- cases do
      FakeTransport.reset!([
        {:ok, status, [], body},
        {:ok, 200, [], Jason.encode!(valid_page())}
      ])

      assert_error(
        WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff),
        :ambiguous_create
      )

      assert length(FakeTransport.requests()) == 1
    end
  end

  test "GET 500 and 502 retain server error classification" do
    for status <- [500, 502] do
      FakeTransport.reset!([{:ok, status, [], "upstream failed"}])

      assert_error(
        WooOrderIndexClient.fetch_manifest_page("manifest-token"),
        :server_error
      )

      assert length(FakeTransport.requests()) == 1
    end
  end

  test "fetch_manifest_page sends one exact-token GET and signs an optional cursor only" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page(has_more: false))}])

    assert {:ok, page} =
             WooOrderIndexClient.fetch_manifest_page("manifest-token", "opaque_cursor.part")

    assert page.boundary_token == "manifest-token"
    assert page.has_more == false
    assert page.next_cursor == nil
    assert page.terminal_evidence == "v1;manifest_sha256=hash;item_count=1;last_sequence=1"

    assert [request] = FakeTransport.requests()
    assert request.method == :get

    assert request.url ==
             "https://wordpress.example.test" <>
               @path <> "/manifest-token?cursor=opaque_cursor.part"

    assert request.body == nil
    assert request.opts == [timeout_ms: 7_000]
    assert List.keyfind(request.headers, "content-type", 0) == nil
    assert List.keyfind(request.headers, "authorization", 0) == nil

    assert List.keyfind(request.headers, "x-eventsales-signature", 0) ==
             {"x-eventsales-signature",
              WooOrderIndexClient.signature(
                "GET",
                @path <> "/manifest-token",
                "cursor=opaque_cursor.part",
                "",
                Integer.to_string(@timestamp),
                "order-index-key-1",
                "order-index-secret"
              )}
  end

  test "fetch_manifest_page without a cursor has no query parameters" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page())}])

    assert {:ok, _page} = WooOrderIndexClient.fetch_manifest_page("manifest-token")

    assert [%{url: "https://wordpress.example.test" <> @path <> "/manifest-token"}] =
             FakeTransport.requests()
  end

  test "invalid GET boundary and cursor values fail before transport" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page())}])

    for boundary_token <- [nil, "", "manifest/token", String.duplicate("x", 129)] do
      assert_error(WooOrderIndexClient.fetch_manifest_page(boundary_token), :invalid_request)
    end

    for cursor <- ["", "not-a-valid-cursor", String.duplicate("x", 513), 42] do
      assert_error(
        WooOrderIndexClient.fetch_manifest_page("manifest-token", cursor),
        :invalid_request
      )
    end

    assert [] = FakeTransport.requests()
  end

  test "GET rejects a response bound to another manifest token" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(Map.put(valid_page(), "boundary_token", "other-token"))}
    ])

    assert_error(WooOrderIndexClient.fetch_manifest_page("manifest-token"), :invalid_response)
    assert length(FakeTransport.requests()) == 1
  end

  test "success validation is closed over the schema, envelope, item identity, and paging proof" do
    invalid_responses = [
      Map.put(valid_page(), "schema_version", "wrong"),
      Map.put(valid_page(), "phase", "wrong"),
      Map.put(valid_page(), "manifest_hash", String.upcase(String.duplicate("a", 64))),
      Map.put(valid_page(), "manifest_hash", "short"),
      Map.put(valid_page(), "boundary_token", ""),
      Map.put(valid_page(), "boundary_token", String.duplicate("x", 129)),
      Map.put(valid_page(), "manifest_expires_at_gmt", "2026-08-13T00:00:00+00:00"),
      Map.put(valid_page(), "source_observed_at_gmt", "not-a-timestamp"),
      Map.put(valid_page(), "items", [
        %{
          "source_order_id" => "0",
          "source_created_at_gmt" => @start,
          "source_modified_at_gmt" => @start
        }
      ]),
      Map.put(valid_page(), "items", [
        %{
          "source_order_id" => "10",
          "source_created_at_gmt" => @start,
          "source_modified_at_gmt" => @start,
          "email" => "customer@example.test"
        }
      ]),
      Map.put(valid_page(), "items", %{}),
      Map.put(valid_page(), "has_more", true)
      |> Map.delete("next_cursor")
      |> Map.put("terminal_evidence", nil),
      Map.put(valid_page(has_more: false), "next_cursor", "cursor"),
      Map.put(valid_page(has_more: false), "terminal_evidence", nil),
      Map.put(valid_page(), "unexpected", true)
    ]

    for response <- invalid_responses do
      FakeTransport.reset!([{:ok, 200, [], Jason.encode!(response)}])
      assert_error(WooOrderIndexClient.fetch_manifest_page("manifest-token"), :invalid_response)
    end
  end

  test "success validation enforces at most 100 items and POST requested limit" do
    too_many = Map.put(valid_page(), "items", List.duplicate(item(), 101))
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(too_many)}])
    assert_error(WooOrderIndexClient.fetch_manifest_page("manifest-token"), :invalid_response)

    eleven_items = Map.put(valid_page(), "items", List.duplicate(item(), 11))
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(eleven_items)}])

    assert_error(
      WooOrderIndexClient.create_manifest(@source_system_id, @start, @cutoff, 10),
      :ambiguous_create
    )
  end

  test "errors never expose credentials, signature, boundary, cursor, or raw response data" do
    secret = "order-index-secret"
    signature = "v1=" <> String.duplicate("a", 64)
    raw = "customer@example.test billing payment line_items #{secret} #{signature}"
    FakeTransport.reset!([{:ok, 200, [], raw}])

    assert {:error, error} =
             WooOrderIndexClient.fetch_manifest_page("sensitive-boundary", "sensitive-cursor.xx")

    inspected = inspect(error)

    for sensitive <- [secret, signature, "sensitive-boundary", "sensitive-cursor.xx", raw] do
      refute inspected =~ sensitive
    end
  end

  test "telemetry contains only bounded order-index metadata" do
    test_pid = self()
    stop_id = "woo-order-index-stop-#{System.unique_integer([:positive])}"
    exception_id = "woo-order-index-exception-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      stop_id,
      EventSales.Telemetry.rest_request_stop(),
      fn _event, _measurements, metadata, _config -> send(test_pid, {:stop, metadata}) end,
      nil
    )

    :telemetry.attach(
      exception_id,
      EventSales.Telemetry.rest_request_exception(),
      fn _event, _measurements, metadata, _config -> send(test_pid, {:exception, metadata}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(stop_id)
      :telemetry.detach(exception_id)
    end)

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_page())}])

    assert {:ok, _page} =
             WooOrderIndexClient.fetch_manifest_page("manifest-token", "sensitive-cursor.xx")

    assert_receive {:stop, stop_metadata}

    assert stop_metadata == %{
             operation: :fetch_manifest_page,
             source: :woo_order_index,
             status: 200
           }

    FakeTransport.reset!([
      {:ok, 200, [],
       "raw body customer@example.test order-index-secret v1=" <> String.duplicate("a", 64)}
    ])

    assert_error(
      WooOrderIndexClient.fetch_manifest_page("manifest-token", "sensitive-cursor.xx"),
      :invalid_json
    )

    assert_receive {:exception, exception_metadata}

    inspected = inspect(stop_metadata) <> inspect(exception_metadata)

    for sensitive <- [
          "order-index-secret",
          "sensitive-cursor.xx",
          "manifest-token",
          "customer@example.test",
          "v1=" <> String.duplicate("a", 64)
        ] do
      refute inspected =~ sensitive
    end
  end

  defp valid_page(opts \\ []) do
    has_more = Keyword.get(opts, :has_more, false)

    base = %{
      "schema_version" => "2026-08-12.v1",
      "phase" => "manifest_enumerate",
      "boundary_token" => "manifest-token",
      "manifest_hash" => String.duplicate("a", 64),
      "manifest_expires_at_gmt" => "2026-08-13T00:00:00.000000Z",
      "source_observed_at_gmt" => "2026-08-12T00:00:00.000000Z",
      "items" => [item()],
      "has_more" => has_more
    }

    if has_more do
      Map.put(base, "next_cursor", "next-cursor.part")
    else
      Map.put(base, "terminal_evidence", "v1;manifest_sha256=hash;item_count=1;last_sequence=1")
    end
  end

  defp item do
    %{
      "source_order_id" => "10",
      "source_created_at_gmt" => "2026-08-01T00:00:00.000000Z",
      "source_modified_at_gmt" => "2026-08-01T00:00:01.000000Z"
    }
  end

  defp assert_error({:error, error}, reason) do
    assert error.__struct__ == WooOrderIndexError
    assert error.reason == reason
    assert is_binary(Exception.message(error))
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
