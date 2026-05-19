defmodule EventSales.Ingestion.Clients.TickeraAttendeeClientTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.Clients.TickeraAttendeeClient
  alias EventSales.Ingestion.Clients.TickeraError

  defmodule FakeTransport do
    @behaviour EventSales.Ingestion.Clients.WooCommerceTransport

    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        request = %{method: method, url: url, headers: headers, body: body, opts: opts}
        {response, %{state | responses: rest, requests: [request | requests]}}
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
    original_config = Application.get_env(:event_sales, :tickera_api)
    original_env = Application.get_env(:event_sales, :env)

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(:event_sales, :tickera_api,
      default_site_url: "https://voelgoed.co.za",
      timeout_ms: 1_000,
      connect_timeout_ms: 500,
      receive_timeout_ms: 1_000,
      per_page: 50,
      page_delay_ms: 100,
      transport: FakeTransport
    )

    on_exit(fn ->
      restore_env(:tickera_api, original_config)
      restore_env(:env, original_env)
    end)

    :ok
  end

  test "builds tickets_info URL, headers, and transport opts without bearer auth" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(%{"data" => [], "additional" => %{}})}])

    assert {:ok, %{attendees: [], count: 0, page: 1, per_page: 50}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "tickera_secret_key",
               1,
               50
             )

    assert [
             %{
               method: :get,
               url: "https://voelgoed.co.za/tc-api/tickera_secret_key/tickets_info/50/1/",
               headers: headers,
               body: nil,
               opts: opts
             }
           ] = FakeTransport.requests()

    assert {"accept", "application/json"} in headers
    assert {"user-agent", "EventSales/1.0 (+https://voelgoed.co.za)"} in headers
    assert {"accept-language", "en-US,en;q=0.9"} in headers
    assert {"accept-encoding", "identity"} in headers
    assert {"cache-control", "no-cache"} in headers
    assert {"pragma", "no-cache"} in headers
    refute List.keymember?(headers, "authorization", 0)
    assert Keyword.fetch!(opts, :timeout_ms) == 1_000
  end

  test "normalizes site URLs and redacts API keys from safe log URLs" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(%{"data" => [], "additional" => %{}})},
      {:ok, 200, [], Jason.encode!(%{"data" => [], "additional" => %{}})}
    ])

    assert {:ok, _} =
             TickeraAttendeeClient.fetch_attendees_page("voelgoed.co.za/", "abc123", 1, 50)

    assert {:ok, _} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za/",
               "abc123",
               2,
               50
             )

    assert [
             %{url: "https://voelgoed.co.za/tc-api/abc123/tickets_info/50/1/"},
             %{url: "https://voelgoed.co.za/tc-api/abc123/tickets_info/50/2/"}
           ] = FakeTransport.requests()

    assert TickeraAttendeeClient.safe_log_url(
             "https://voelgoed.co.za/tc-api/abc123/tickets_info/50/1/"
           ) == "https://voelgoed.co.za/tc-api/[REDACTED]/tickets_info/50/1/"
  end

  test "allows http site URLs outside prod but rejects them in prod" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(%{"data" => [], "additional" => %{}})}])

    assert {:ok, _} =
             TickeraAttendeeClient.fetch_attendees_page(
               "http://localhost:4000",
               "dev_key",
               1,
               50
             )

    Application.put_env(:event_sales, :env, :prod)

    assert {:error, %TickeraError{reason: :misconfigured}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "http://localhost:4000",
               "dev_key",
               1,
               50
             )
  end

  test "rejects non-positive page and per-page arguments before transport" do
    FakeTransport.reset!([{:ok, 200, [], "[]"}])

    for {page, per_page} <- [{0, 50}, {-1, 50}, {1, 0}, {1, -1}] do
      assert {:error, %TickeraError{reason: :invalid_request}} =
               TickeraAttendeeClient.fetch_attendees_page(
                 "https://voelgoed.co.za",
                 "abc123",
                 page,
                 per_page
               )
    end

    assert [] = FakeTransport.requests()
  end

  test "does not apply an artificial upper cap to page or per_page" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(%{"data" => [], "additional" => %{}})}])

    assert {:ok, %{page: 10_000, per_page: 500, attendees: []}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               10_000,
               500
             )

    assert [
             %{url: "https://voelgoed.co.za/tc-api/abc123/tickets_info/500/10000/"}
           ] = FakeTransport.requests()
  end

  test "parses data-list response shape and normalizes attendee fields" do
    body =
      Jason.encode!(%{
        "data" => [
          %{
            "ticket_code" => "TICKET-1",
            "checksum" => "checksum-1",
            "ticket_type_id" => "123",
            "first_name" => " Ada ",
            "last_name" => " Lovelace ",
            "email" => " ada@example.test ",
            "buyer_first" => "Buyer",
            "buyer_last" => "Person",
            "buyer_email" => "buyer@example.test",
            "allowed_checkins" => "2",
            "checkins" => "1",
            "checked-in" => "yes",
            "payment_date" => "2026-05-01 10:00:00",
            "transaction_id" => "txn_private",
            "custom_fields" => [
              %{"name" => " Ticket Type ", "value" => " General Admission "}
            ]
          }
        ],
        "additional" => %{"results_count" => 50}
      })

    FakeTransport.reset!([{:ok, 200, [], body}])

    assert {:ok, %{attendees: [attendee], count: 1, additional: %{"results_count" => 50}}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )

    assert attendee == %{
             ticket_code: "TICKET-1",
             checksum: "checksum-1",
             ticket_type_id: 123,
             ticket_type: "General Admission",
             first_name: "Ada",
             last_name: "Lovelace",
             email: "ada@example.test",
             buyer_first: "Buyer",
             buyer_last: "Person",
             buyer_email: "buyer@example.test",
             allowed_checkins: 2,
             used_checkins: 1,
             remaining_checkins: 1,
             checked_in?: true,
             payment_status: "completed",
             payment_date: "2026-05-01 10:00:00",
             transaction_id: "txn_private",
             custom_fields: %{"Ticket Type" => "General Admission"}
           }
  end

  test "parses list-root wrapped data and additional metadata shape" do
    body =
      Jason.encode!([
        %{
          "data" => %{
            "checksum" => "checksum-only",
            "ticket_type_id" => "invalid",
            "custom_fields" => %{
              "Attendee First Name" => "Grace",
              "Attendee Last Name" => "Hopper",
              "Attendee Email" => "grace@example.test",
              "payment_status" => "wc-completed"
            }
          }
        },
        %{"additional" => %{"execution_time" => "0.1", "results_count" => 100}}
      ])

    FakeTransport.reset!([{:ok, 200, [], body}])

    assert {:ok,
            %{
              attendees: [
                %{
                  ticket_code: "checksum-only",
                  checksum: "checksum-only",
                  ticket_type_id: nil,
                  first_name: "Grace",
                  last_name: "Hopper",
                  email: "grace@example.test",
                  payment_status: "completed"
                }
              ],
              additional: %{"execution_time" => "0.1", "results_count" => 100}
            }} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )
  end

  test "parses list-root direct ticket maps and buyer identity fallback" do
    body =
      Jason.encode!([
        %{
          "checksum" => "checksum-2",
          "buyer_first" => "Buyer",
          "buyer_last" => "Fallback",
          "buyer_email" => "buyer@example.test",
          "custom_fields" => [["Attendee Ticket", "VIP"]]
        }
      ])

    FakeTransport.reset!([{:ok, 200, [], body}])

    assert {:ok, %{attendees: [attendee], count: 1}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )

    assert %{
             ticket_code: "checksum-2",
             first_name: "Buyer",
             last_name: "Fallback",
             email: "buyer@example.test",
             ticket_type: "VIP"
           } = attendee
  end

  test "uses buyer e-mail custom fields for buyer and attendee email fallback" do
    body =
      Jason.encode!([
        %{
          "data" => %{
            "checksum" => "abc123",
            "buyer_first" => "Jan",
            "buyer_last" => "Smit",
            "custom_fields" => [
              ["Buyer E-mail", "jan@example.com"]
            ]
          }
        },
        %{"additional" => %{"results_count" => 1}}
      ])

    FakeTransport.reset!([{:ok, 200, [], body}])

    assert {:ok, %{attendees: [attendee], count: 1, additional: %{"results_count" => 1}}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )

    assert %{
             first_name: "Jan",
             last_name: "Smit",
             email: "jan@example.com",
             buyer_first: "Jan",
             buyer_last: "Smit",
             buyer_email: "jan@example.com"
           } = attendee
  end

  test "generic Tickera status is not normalized as payment status" do
    body =
      Jason.encode!(%{
        "data" => [
          %{"checksum" => "status-only", "status" => "active"}
        ]
      })

    FakeTransport.reset!([{:ok, 200, [], body}])

    assert {:ok, %{attendees: [%{payment_status: nil}]}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )
  end

  test "custom order and payment status fields are normalized" do
    body =
      Jason.encode!(%{
        "data" => [
          %{
            "checksum" => "order-status",
            "custom_fields" => [["Order Status", "wc-completed"]]
          },
          %{
            "checksum" => "payment-status",
            "custom_fields" => [["Payment Status", "on-hold"]]
          }
        ]
      })

    FakeTransport.reset!([{:ok, 200, [], body}])

    assert {:ok, %{attendees: [order_status, payment_status]}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )

    assert order_status.payment_status == "completed"
    assert payment_status.payment_status == "pending"
  end

  test "distinguishes valid JSON with no attendees from invalid JSON and empty success bodies" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(%{"unexpected" => "shape"})},
      {:ok, 200, [], "not-json"},
      {:ok, 200, [], ""}
    ])

    assert {:ok, %{attendees: [], count: 0}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )

    assert {:error, %TickeraError{reason: :invalid_json, retryable?: false}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )

    assert {:error, %TickeraError{reason: :invalid_json, retryable?: false}} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "abc123",
               1,
               50
             )
  end

  test "invalid JSON and empty success bodies emit exception telemetry without stop telemetry" do
    FakeTransport.reset!([
      {:ok, 200, [], "not-json"},
      {:ok, 200, [], ""}
    ])

    test_pid = self()
    stop_id = "tickera-invalid-stop-#{System.unique_integer([:positive])}"
    exception_id = "tickera-invalid-exception-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      stop_id,
      EventSales.Telemetry.tickera_request_stop(),
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:unexpected_stop, metadata})
      end,
      nil
    )

    :telemetry.attach(
      exception_id,
      EventSales.Telemetry.tickera_request_exception(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:tickera_exception, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(stop_id)
      :telemetry.detach(exception_id)
    end)

    for _ <- 1..2 do
      assert {:error, %TickeraError{reason: :invalid_json}} =
               TickeraAttendeeClient.fetch_attendees_page(
                 "https://voelgoed.co.za",
                 "abc123",
                 1,
                 50
               )

      assert_receive {:tickera_exception, %{count: 1}, %{reason: :invalid_json}}
      refute_receive {:unexpected_stop, _metadata}, 20
    end
  end

  test "maps HTTP statuses and transport failures to typed retryability" do
    cases = [
      {{:ok, 401, [], "{}"}, :unauthorized, false},
      {{:ok, 403, [], "{}"}, :forbidden, false},
      {{:ok, 404, [], "{}"}, :not_found, false},
      {{:ok, 429, [], "{}"}, :rate_limited, true},
      {{:ok, 418, [], "{}"}, :client_error, false},
      {{:ok, 500, [], "{}"}, :server_error, true},
      {{:error, :timeout}, :timeout, true},
      {{:error, :econnrefused}, :transport_error, true},
      {{:raise, "transport exploded"}, :transport_error, true}
    ]

    for {response, reason, retryable?} <- cases do
      FakeTransport.reset!([response])

      assert {:error,
              %TickeraError{
                reason: ^reason,
                retryable?: ^retryable?,
                operation: :fetch_attendees_page
              }} =
               TickeraAttendeeClient.fetch_attendees_page(
                 "https://voelgoed.co.za",
                 "abc123",
                 1,
                 50
               )
    end
  end

  test "telemetry and error messages omit secrets URLs PII transaction ids and bodies" do
    FakeTransport.reset!([
      {:ok, 200, [],
       Jason.encode!(%{
         "data" => [
           %{
             "ticket_code" => "SECRET-TICKET",
             "first_name" => "Ada",
             "email" => "ada@example.test",
             "transaction_id" => "txn_private"
           }
         ]
       })},
      {:ok, 500, [], "server body with ada@example.test txn_private tickera_secret_key"}
    ])

    test_pid = self()
    stop_id = "tickera-stop-#{System.unique_integer([:positive])}"
    exception_id = "tickera-exception-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      stop_id,
      EventSales.Telemetry.tickera_request_stop(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:tickera_stop, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      exception_id,
      EventSales.Telemetry.tickera_request_exception(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:tickera_exception, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(stop_id)
      :telemetry.detach(exception_id)
    end)

    assert {:ok, _} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "tickera_secret_key",
               1,
               50
             )

    assert_receive {:tickera_stop, %{count: 1, duration: duration}, stop_metadata}
    assert is_integer(duration)

    assert stop_metadata == %{
             operation: :fetch_attendees_page,
             endpoint: :tickets_info,
             page: 1,
             per_page: 50,
             status: 200,
             source: :tickera
           }

    assert {:error, %TickeraError{} = error} =
             TickeraAttendeeClient.fetch_attendees_page(
               "https://voelgoed.co.za",
               "tickera_secret_key",
               1,
               50
             )

    assert_receive {:tickera_exception, %{count: 1}, exception_metadata}

    assert exception_metadata == %{
             operation: :fetch_attendees_page,
             endpoint: :tickets_info,
             page: 1,
             per_page: 50,
             reason: :server_error,
             retryable?: true,
             source: :tickera,
             status: 500
           }

    for forbidden <- [
          "tickera_secret_key",
          "voelgoed.co.za",
          "SECRET-TICKET",
          "Ada",
          "ada@example.test",
          "txn_private",
          "server body"
        ] do
      refute inspect(stop_metadata) =~ forbidden
      refute inspect(exception_metadata) =~ forbidden
      refute Exception.message(error) =~ forbidden
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
