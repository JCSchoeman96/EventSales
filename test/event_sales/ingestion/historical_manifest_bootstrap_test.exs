defmodule EventSales.Ingestion.HistoricalManifestBootstrapTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.WooOrderIndexClient
  alias EventSales.Ingestion.HistoricalManifestBootstrap
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.TestSupport.SalesHelpers

  @source_url "https://store.example.test"
  @date_from ~U[2026-08-01 08:00:00.123456Z]
  @date_to ~U[2026-08-09 23:59:59.999999Z]
  @now ~U[2026-08-13 12:00:00.000000Z]
  @manifest_expires_at ~U[2026-08-13 13:00:00.000000Z]
  @source_observed_at ~U[2026-08-13 11:00:00.000000Z]

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
    end
  end

  defmodule BlockingClient do
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do:
        Agent.start_link(fn -> %{owner: nil, calls: 0, block_endpoint: false} end,
          name: __MODULE__
        )

    def reset!(owner, opts \\ []) do
      block_endpoint = Keyword.get(opts, :block_endpoint, false)

      Agent.update(__MODULE__, fn _state ->
        %{owner: owner, calls: 0, block_endpoint: block_endpoint}
      end)
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def configured_base_url(_opts) do
      case Agent.get(__MODULE__, & &1) do
        %{owner: owner, block_endpoint: true} = _state ->
          send(owner, {:endpoint_validation_ready, self()})

          receive do
            :release_endpoint_validation -> {:ok, "https://store.example.test"}
          after
            5_000 -> {:error, :timeout}
          end

        _state ->
          {:ok, "https://store.example.test"}
      end
    end

    def create_manifest(_source_system_id, _date_from, _date_to, _limit) do
      owner =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.owner, %{state | calls: state.calls + 1}}
        end)

      send(owner, {:manifest_post_started, self()})

      receive do
        {:release_manifest_post, response} -> response
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  setup do
    start_supervised!(FakeTransport)
    start_supervised!(BlockingClient)

    original_config = Application.get_env(:event_sales, :woo_order_index)
    original_env = Application.get_env(:event_sales, :env)

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(:event_sales, :woo_order_index,
      base_url: @source_url,
      key_id: "test-order-index-key",
      secret: "test-order-index-secret",
      timeout_ms: 7_000,
      transport: FakeTransport,
      clock: fn -> 1_780_000_000 end
    )

    source = SalesHelpers.create_source_system!(%{base_url: @source_url})
    event = create_event!(source)
    run = create_historical_run!(source, event)
    cursor = create_cursor!(run)

    on_exit(fn ->
      restore_env(:woo_order_index, original_config)
      restore_env(:env, original_env)
    end)

    {:ok, source: source, event: event, run: run, cursor: cursor}
  end

  test "valid historical run creates and persists bounded evidence", %{run: run, cursor: cursor} do
    FakeTransport.reset!([manifest_response()])

    assert {:ok, evidence} = ensure_manifest(run.id)
    assert evidence.state == "pending_first_page"
    assert evidence.boundary_token == "manifest-token"
    assert evidence.manifest_hash == String.duplicate("a", 64)

    persisted = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert persisted.metadata == HistoricalManifestEvidence.metadata(evidence)
    assert byte_size(Jason.encode!(persisted.metadata)) <= 2048
  end

  test "create receives the persisted source UUID, bounds, and limit at most 100", %{
    source: source,
    run: run
  } do
    FakeTransport.reset!([manifest_response()])

    assert {:ok, _evidence} = ensure_manifest(run.id)
    assert [request] = FakeTransport.requests()
    assert request.method == :post

    assert Jason.decode!(request.body) == %{
             "source_system" => source.id,
             "backfill_start" => DateTime.to_iso8601(run.date_from),
             "backfill_cutoff" => DateTime.to_iso8601(run.date_to),
             "limit" => 100
           }
  end

  test "configured endpoint matches SourceSystem after canonical normalization", %{run: run} do
    Application.put_env(:event_sales, :woo_order_index,
      base_url: "  #{@source_url}/// ",
      key_id: "test-order-index-key",
      secret: "test-order-index-secret",
      transport: FakeTransport,
      clock: fn -> 1_780_000_000 end
    )

    FakeTransport.reset!([manifest_response()])

    assert {:ok, _evidence} = ensure_manifest(run.id)
    assert [%{method: :post}] = FakeTransport.requests()
  end

  test "endpoint mismatch fails before transport", %{run: run, cursor: cursor} do
    put_endpoint_config("https://other.example.test")
    FakeTransport.reset!([])

    assert {:error, :source_endpoint_mismatch} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == %{}
  end

  test "inactive SourceSystem fails before transport", %{source: source, run: run, cursor: cursor} do
    assert {:ok, _inactive} = Ash.update(source, %{}, action: :deactivate, domain: Catalog)
    FakeTransport.reset!([])

    assert {:error, :source_system_inactive} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == %{}
  end

  test "non-historical SyncRun fails before transport", %{source: source, event: event} do
    run = create_manual_run!(source, event)
    cursor = create_cursor!(run)
    FakeTransport.reset!([])

    assert {:error, :not_historical_backfill} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == %{}
  end

  test "invalid persisted historical bounds fail before transport", %{run: run, cursor: cursor} do
    FakeTransport.reset!([])

    for invalid_run <- [
          %{run | date_from: nil},
          %{run | date_from: "not-a-date"},
          %{run | date_to: nil},
          %{run | date_to: "not-a-date"},
          %{run | date_from: @date_to, date_to: @date_from}
        ] do
      assert {:error, _reason} =
               ensure_manifest(run.id, test_sync_run_loader: fn _id -> {:ok, invalid_run} end)

      assert [] = FakeTransport.requests()
      assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == %{}
    end
  end

  test "cursor must remain the initial active cursor", %{run: run, cursor: cursor} do
    mismatches = [
      %{cursor | sync_run_id: Ecto.UUID.generate()},
      %{cursor | status: :done},
      %{cursor | page: 2},
      %{cursor | modified_after: DateTime.add(run.date_from, 1, :second)},
      %{cursor | modified_before: DateTime.add(run.date_to, -1, :second)},
      %{cursor | last_seen_order_id: 42}
    ]

    for invalid_cursor <- mismatches do
      FakeTransport.reset!([])

      assert {:error, :invalid_initial_cursor} =
               ensure_manifest(run.id,
                 test_sync_cursor_loader: fn _run -> {:ok, invalid_cursor} end
               )

      assert [] = FakeTransport.requests()
      assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == %{}
    end
  end

  test "concurrent bootstraps authorize at most one manifest POST", %{run: run, cursor: cursor} do
    BlockingClient.reset!(self(), block_endpoint: true)

    first =
      Task.async(fn ->
        ensure_manifest(run.id, client: BlockingClient)
      end)

    second =
      Task.async(fn ->
        ensure_manifest(run.id, client: BlockingClient)
      end)

    assert_receive {:endpoint_validation_ready, first_endpoint_pid}, 5_000
    assert_receive {:endpoint_validation_ready, second_endpoint_pid}, 5_000

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == %{}

    send(first_endpoint_pid, :release_endpoint_validation)
    send(second_endpoint_pid, :release_endpoint_validation)

    assert_receive {:manifest_post_started, first_post_pid}, 5_000

    send(first_post_pid, {:release_manifest_post, {:ok, page()}})
    assert {:ok, _evidence} = Task.await(first, 5_000)

    assert second_result = Task.await(second, 5_000)
    assert second_result == {:error, :manifest_create_in_doubt} or match?({:ok, _}, second_result)
    assert BlockingClient.calls() == 1
  end

  test "a durable claim is present while the source POST is blocked", %{
    run: run,
    cursor: cursor
  } do
    BlockingClient.reset!(self())

    task =
      Task.async(fn ->
        ensure_manifest(run.id, client: BlockingClient)
      end)

    assert_receive {:manifest_post_started, post_pid}, 5_000

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata ==
             HistoricalManifestEvidence.claim_metadata()

    send(post_pid, {:release_manifest_post, {:ok, page()}})
    assert {:ok, _evidence} = Task.await(task, 5_000)
  end

  test "successful bootstrap performs one POST and zero GETs", %{run: run} do
    FakeTransport.reset!([manifest_response()])

    assert {:ok, _evidence} = ensure_manifest(run.id)
    assert [request] = FakeTransport.requests()
    assert request.method == :post
    refute Enum.any?(FakeTransport.requests(), &(&1.method == :get))
  end

  test "first page items and continuation are validated but never persisted", %{
    run: run,
    cursor: cursor
  } do
    FakeTransport.reset!([manifest_response()])

    assert {:ok, _evidence} = ensure_manifest(run.id)
    persisted = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    refute inspect(persisted.metadata) =~ "source_order_id"
    refute inspect(persisted.metadata) =~ "next_cursor"
    refute inspect(persisted.metadata) =~ "9001"
  end

  test "cursor progress and run state/counts remain unchanged", %{run: run, cursor: cursor} do
    before_run = Ash.get!(SyncRun, run.id, domain: Ingestion)
    before_cursor = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    FakeTransport.reset!([manifest_response()])

    assert {:ok, _evidence} = ensure_manifest(run.id)

    after_run = Ash.get!(SyncRun, run.id, domain: Ingestion)
    after_cursor = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)

    assert after_run.status == before_run.status
    assert after_run.started_at == before_run.started_at
    assert after_run.finished_at == before_run.finished_at
    assert after_run.orders_seen_count == before_run.orders_seen_count
    assert after_run.orders_matched_count == before_run.orders_matched_count
    assert after_run.orders_upserted_count == before_run.orders_upserted_count
    assert after_run.orders_stale_count == before_run.orders_stale_count
    assert after_run.orders_failed_count == before_run.orders_failed_count
    assert after_run.errors_count == before_run.errors_count
    assert after_cursor.page == before_cursor.page
    assert after_cursor.modified_after == before_cursor.modified_after
    assert after_cursor.modified_before == before_cursor.modified_before
    assert after_cursor.last_seen_order_id == before_cursor.last_seen_order_id
    assert after_cursor.status == before_cursor.status
  end

  test "second bootstrap reuses valid evidence without HTTP", %{run: run} do
    FakeTransport.reset!([manifest_response()])
    assert {:ok, first} = ensure_manifest(run.id)

    FakeTransport.reset!([])
    assert {:ok, second} = ensure_manifest(run.id)
    assert second == first
    assert [] = FakeTransport.requests()
  end

  test "progressed and terminal evidence are reused without another manifest POST", %{
    run: run,
    cursor: cursor
  } do
    {:ok, evidence} =
      HistoricalManifestEvidence.from_metadata(evidence_metadata(@manifest_expires_at))

    in_progress =
      HistoricalManifestEvidence.in_progress_metadata(evidence, "cursor1234567890.next")

    replace_cursor_metadata!(cursor, in_progress)
    FakeTransport.reset!([])

    assert {:ok, %HistoricalManifestEvidence{state: "manifest_in_progress"}} =
             ensure_manifest(run.id)

    terminal = HistoricalManifestEvidence.terminal_metadata(evidence, "terminal-proof")
    replace_cursor_metadata!(cursor, terminal)

    assert {:ok, %HistoricalManifestEvidence{state: "manifest_terminal"}} =
             ensure_manifest(run.id)

    assert [] = FakeTransport.requests()
  end

  test "partial or corrupt evidence fails closed without overwrite", %{run: run, cursor: cursor} do
    for metadata <- [
          %{"historical_manifest" => %{"state" => "pending_first_page"}},
          %{"historical_manifest" => "not-a-map"},
          %{historical_manifest: %{"state" => "pending_first_page"}},
          %{
            "historical_manifest" => %{
              "schema_version" => "wrong",
              "phase" => "manifest_enumerate",
              "boundary_token" => "manifest-token",
              "manifest_hash" => String.duplicate("a", 64),
              "manifest_expires_at_gmt" => DateTime.to_iso8601(@manifest_expires_at),
              "source_observed_at_gmt" => DateTime.to_iso8601(@source_observed_at),
              "state" => "pending_first_page"
            }
          }
        ] do
      replace_cursor_metadata!(cursor, metadata)
      before = Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata
      FakeTransport.reset!([])

      assert {:error, :corrupt_manifest_evidence} = ensure_manifest(run.id)
      assert [] = FakeTransport.requests()
      assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == before
    end
  end

  test "expired existing evidence fails closed without rebuilding", %{run: run, cursor: cursor} do
    metadata = evidence_metadata(@now |> DateTime.add(-1, :second))
    replace_cursor_metadata!(cursor, metadata)
    FakeTransport.reset!([])

    assert {:error, :manifest_expired} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == metadata
  end

  test "existing create claim fails closed without an HTTP request", %{run: run, cursor: cursor} do
    claim = HistoricalManifestEvidence.claim_metadata()
    replace_cursor_metadata!(cursor, claim)
    FakeTransport.reset!([manifest_response()])

    assert {:error, :manifest_create_in_doubt} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata == claim
  end

  test "ambiguous create performs one attempt and retains the durable claim", %{
    run: run,
    cursor: cursor
  } do
    FakeTransport.reset!([{:error, :timeout}, manifest_response()])

    assert {:error, :ambiguous_create} = ensure_manifest(run.id)
    assert length(FakeTransport.requests()) == 1

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata ==
             HistoricalManifestEvidence.claim_metadata()

    FakeTransport.reset!([manifest_response()])
    assert {:error, :manifest_create_in_doubt} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
  end

  test "known deterministic source failure retains the durable claim and is not retried", %{
    run: run,
    cursor: cursor
  } do
    FakeTransport.reset!([
      {:ok, 503, [], Jason.encode!(%{"error" => "source_preflight_failed"})},
      manifest_response()
    ])

    assert {:error, :source_preflight_failed} = ensure_manifest(run.id)
    assert length(FakeTransport.requests()) == 1

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata ==
             HistoricalManifestEvidence.claim_metadata()

    FakeTransport.reset!([manifest_response()])
    assert {:error, :manifest_create_in_doubt} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
  end

  test "successful create with evidence persistence failure is distinct and not retried", %{
    run: run,
    cursor: cursor
  } do
    FakeTransport.reset!([manifest_response(), manifest_response()])

    assert {:error, :manifest_evidence_persist_failed} =
             ensure_manifest(run.id,
               test_evidence_persister: fn _cursor, _metadata -> {:error, :db} end
             )

    assert length(FakeTransport.requests()) == 1

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata ==
             HistoricalManifestEvidence.claim_metadata()

    FakeTransport.reset!([manifest_response()])
    assert {:error, :manifest_create_in_doubt} = ensure_manifest(run.id)
    assert [] = FakeTransport.requests()
  end

  test "configured_base_url returns only normalized URL and no credential material" do
    assert {:ok, @source_url} = WooOrderIndexClient.configured_base_url()
    refute inspect(WooOrderIndexClient.configured_base_url()) =~ "test-order-index-key"
    refute inspect(WooOrderIndexClient.configured_base_url()) =~ "test-order-index-secret"
  end

  test "bootstrap errors expose no source secrets, tokens, PII, payment data, or IDs", %{
    run: run
  } do
    sensitive_values = [
      "test-order-index-secret",
      "v1=" <> String.duplicate("b", 64),
      "sensitive-boundary",
      "sensitive-cursor.xx",
      "customer@example.test",
      "payment-token-123",
      "source-order-id-9001"
    ]

    FakeTransport.reset!([
      {:ok, 400, [], Jason.encode!(%{"error" => Enum.join(sensitive_values, " ")})}
    ])

    result = ensure_manifest(run.id)
    inspected = inspect(result)

    refute Enum.any?(sensitive_values, &String.contains?(inspected, &1))
  end

  test "SyncCursor evidence action updates metadata only", %{run: run, cursor: cursor} do
    metadata = evidence_metadata(@manifest_expires_at)

    assert {:ok, updated} =
             Ash.update(cursor, %{metadata: metadata},
               action: :record_manifest_evidence,
               domain: Ingestion
             )

    assert updated.metadata == metadata
    assert updated.page == cursor.page
    assert updated.modified_after == cursor.modified_after
    assert updated.modified_before == cursor.modified_before
    assert updated.last_seen_order_id == cursor.last_seen_order_id
    assert updated.status == cursor.status
    assert updated.sync_run_id == run.id
  end

  test "SyncCursor claim action updates metadata only", %{run: run, cursor: cursor} do
    metadata = HistoricalManifestEvidence.claim_metadata()

    assert {:ok, updated} =
             Ash.update(cursor, %{metadata: metadata},
               action: :claim_manifest_create,
               domain: Ingestion
             )

    assert updated.metadata == metadata
    assert updated.page == cursor.page
    assert updated.modified_after == cursor.modified_after
    assert updated.modified_before == cursor.modified_before
    assert updated.last_seen_order_id == cursor.last_seen_order_id
    assert updated.status == cursor.status
    assert updated.sync_run_id == run.id
  end

  test "manifest claim and pending evidence metadata stay within the durable bound" do
    assert {:ok, claim_size} =
             HistoricalManifestEvidence.encoded_size(HistoricalManifestEvidence.claim_metadata())

    assert claim_size <= HistoricalManifestEvidence.metadata_max_bytes()

    assert {:ok, evidence} = HistoricalManifestEvidence.from_page(page())

    assert {:ok, pending_size} =
             evidence
             |> HistoricalManifestEvidence.metadata()
             |> HistoricalManifestEvidence.encoded_size()

    assert pending_size <= HistoricalManifestEvidence.metadata_max_bytes()
  end

  test "manifest metadata state distinguishes missing, claimed, pending, and corrupt" do
    assert HistoricalManifestEvidence.state(%{}) == :missing
    assert HistoricalManifestEvidence.state(%{"other" => "value"}) == :missing

    assert HistoricalManifestEvidence.state(HistoricalManifestEvidence.claim_metadata()) ==
             :create_claimed

    assert HistoricalManifestEvidence.state(evidence_metadata(@manifest_expires_at)) ==
             :pending_first_page

    assert HistoricalManifestEvidence.state(%{
             "historical_manifest" => %{"state" => "create_claimed", "extra" => "x"}
           }) == :corrupt
  end

  test "evidence continuity validation is pure and deterministic" do
    page = page()
    assert {:ok, evidence} = HistoricalManifestEvidence.from_page(page)
    assert :ok = HistoricalManifestEvidence.validate_continuity(evidence, page)

    mismatched = Map.put(page, "manifest_hash", String.duplicate("b", 64))

    assert {:error, :manifest_continuity_mismatch} =
             HistoricalManifestEvidence.validate_continuity(evidence, mismatched)
  end

  defp ensure_manifest(run_id, opts \\ []) do
    HistoricalManifestBootstrap.ensure_manifest(run_id, Keyword.put_new(opts, :now, @now))
  end

  defp manifest_response do
    {:ok, 200, [], Jason.encode!(page())}
  end

  defp page(opts \\ []) do
    has_more = Keyword.get(opts, :has_more, true)

    base = %{
      "schema_version" => "2026-08-12.v1",
      "phase" => "manifest_enumerate",
      "boundary_token" => "manifest-token",
      "manifest_hash" => String.duplicate("a", 64),
      "manifest_expires_at_gmt" => DateTime.to_iso8601(@manifest_expires_at),
      "source_observed_at_gmt" => DateTime.to_iso8601(@source_observed_at),
      "items" => [
        %{
          "source_order_id" => "9001",
          "source_created_at_gmt" => "2026-08-04T10:00:00Z",
          "source_modified_at_gmt" => "2026-08-04T10:00:00Z"
        }
      ],
      "has_more" => has_more
    }

    if has_more do
      Map.put(base, "next_cursor", "cursor1234567890.next")
    else
      Map.put(base, "terminal_evidence", "terminal-proof")
    end
  end

  defp evidence_metadata(expires_at) do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => "manifest-token",
        "manifest_hash" => String.duplicate("a", 64),
        "manifest_expires_at_gmt" => DateTime.to_iso8601(expires_at),
        "source_observed_at_gmt" => DateTime.to_iso8601(@source_observed_at),
        "state" => "pending_first_page"
      }
    }
  end

  defp put_endpoint_config(base_url) do
    Application.put_env(:event_sales, :woo_order_index,
      base_url: base_url,
      key_id: "test-order-index-key",
      secret: "test-order-index-secret",
      transport: FakeTransport,
      clock: fn -> 1_780_000_000 end
    )
  end

  defp create_event!(source) do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical Manifest",
        slug: "historical-manifest-#{System.unique_integer([:positive])}",
        external_event_id: 70_500 + System.unique_integer([:positive]),
        external_event_kind: :tickera_event
      })

    Ash.update!(
      event,
      %{source_created_at: @date_from},
      action: :capture_source_created_at,
      domain: Catalog,
      context: %{event_sales_backfill_start_capture_authority: {Event, :verified}}
    )
  end

  defp create_historical_run!(source, event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @date_to
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
    |> Ash.Changeset.force_change_attribute(:date_from, @date_from)
    |> Ash.create!(domain: Ingestion)
  end

  defp create_manual_run!(source, event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_manual_scoped, %{
      source_system_id: source.id,
      event_id: event.id,
      date_from: @date_from,
      date_to: DateTime.add(@date_from, 3_600, :second),
      sync_mode: :shallow,
      requested_via: :manual
    })
    |> Ash.create!(domain: Ingestion, context: %{scoped_manual_sync_now: @now})
  end

  defp create_cursor!(run) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      last_seen_order_id: nil,
      metadata: %{}
    })
    |> Ash.create!(domain: Ingestion)
  end

  defp replace_cursor_metadata!(cursor, metadata) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: cursor.sync_run_id,
      page: cursor.page,
      modified_after: cursor.modified_after,
      modified_before: cursor.modified_before,
      last_seen_order_id: cursor.last_seen_order_id,
      metadata: metadata
    })
    |> Ash.create!(domain: Ingestion)
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
