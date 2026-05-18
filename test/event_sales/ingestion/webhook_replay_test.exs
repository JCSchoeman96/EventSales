defmodule EventSales.Ingestion.WebhookReplayTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Ingestion.WebhookReplay
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.Repo
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    Repo.delete_all(from(j in Oban.Job))

    source = SalesHelpers.create_source_system!()
    admin = create_user!("webhook-replay-admin@example.com")
    staff = create_user!("webhook-replay-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    original_enqueue = Application.get_env(:event_sales, :webhook_replay_enqueue)
    original_audit = Application.get_env(:event_sales, :webhook_replay_audit_logger)

    on_exit(fn ->
      restore_env(:webhook_replay_enqueue, original_enqueue)
      restore_env(:webhook_replay_audit_logger, original_audit)
      Repo.delete_all(from(j in Oban.Job))
    end)

    {:ok, source: source, admin: admin, staff: staff}
  end

  test "failed replay queues existing event and enqueues process worker", %{
    source: source,
    admin: admin
  } do
    failed = failed_event!(source, processing_attempt_count: 3)

    assert {:ok, replayed} = WebhookReplay.replay_failed(failed.id, actor: admin)

    assert replayed.id == failed.id
    assert replayed.status == :queued
    assert replayed.processing_attempt_count == 3
    refute replayed.failed_at
    refute replayed.error_message
    refute replayed.ignore_reason
    refute replayed.processed_at
    refute replayed.processing_started_at

    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => failed.id})
  end

  test "non-admin and non-failed events cannot be replayed", %{
    source: source,
    admin: admin,
    staff: staff
  } do
    failed = failed_event!(source)
    {:ok, queued} = create_event(source)

    assert {:error, :forbidden} = WebhookReplay.replay_failed(failed.id, actor: staff)
    assert {:error, :forbidden} = WebhookReplay.replay_failed(failed.id, actor: nil)
    assert {:error, :not_failed} = WebhookReplay.replay_failed(queued.id, actor: admin)
    assert [] = all_enqueued(worker: ProcessWebhookWorker)
  end

  test "enqueue failure returns enqueue_failed and audits rejected outcome", %{
    source: source,
    admin: admin
  } do
    Application.put_env(:event_sales, :webhook_replay_enqueue, __MODULE__.FailingEnqueue)
    failed = failed_event!(source)

    assert {:error, :enqueue_failed} = WebhookReplay.replay_failed(failed.id, actor: admin)

    replayed = Ash.get!(WebhookEvent, failed.id, domain: Ingestion)
    assert replayed.status == :queued
    assert [] = all_enqueued(worker: ProcessWebhookWorker)

    assert [audit] = Ash.read!(AuditLog, domain: Audit)
    assert audit.event_type == :webhook_replay_requested
    assert audit.subject_id == failed.id
    assert audit.metadata["result"] == "rejected"
    assert audit.metadata["reason"] == "enqueue_failed"
  end

  test "successful replay audit contains only safe identifiers and outcome", %{
    source: source,
    admin: admin
  } do
    failed =
      failed_event!(source,
        payload: %{
          "id" => 123,
          "billing" => %{"email" => "customer@example.test"},
          "customer" => %{"first_name" => "Private"}
        },
        sanitized_headers_snapshot: %{"x-wc-webhook-signature" => "secret-signature"}
      )

    assert {:ok, _event} = WebhookReplay.replay_failed(failed.id, actor: admin)

    assert [audit] = Ash.read!(AuditLog, domain: Audit)
    assert audit.event_type == :webhook_replay_requested
    assert audit.metadata["webhook_event_id"] == failed.id
    assert audit.metadata["delivery_id"] == failed.delivery_id
    assert audit.metadata["topic"] == failed.topic
    assert audit.metadata["resource_type"] == failed.resource_type
    assert audit.metadata["resource_id"] == failed.resource_id
    assert audit.metadata["previous_status"] == "failed"
    assert audit.metadata["result"] == "queued"
    refute Map.has_key?(audit.metadata, "payload")
    refute Map.has_key?(audit.metadata, "raw_body")
    refute Map.has_key?(audit.metadata, "headers")
    refute Map.has_key?(audit.metadata, "signature")
    refute Map.has_key?(audit.metadata, "sanitized_headers_snapshot")
    refute inspect(audit.metadata) =~ "customer@example.test"
    refute inspect(audit.metadata) =~ "secret-signature"
  end

  test "audit failure after successful enqueue emits telemetry and keeps replay successful", %{
    source: source,
    admin: admin
  } do
    Application.put_env(:event_sales, :webhook_replay_audit_logger, __MODULE__.FailingAudit)
    failed = failed_event!(source)
    test_pid = self()
    handler_id = "webhook-replay-audit-failed-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.webhook_replay_audit_failed(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, replayed} = WebhookReplay.replay_failed(failed.id, actor: admin)
    assert replayed.status == :queued
    assert length(process_webhook_jobs(failed.id)) == 1

    assert_receive {:telemetry, [:event_sales, :webhook, :replay, :audit_failed], %{count: 1},
                    %{webhook_event_id: event_id, reason: :audit_down}},
                   500

    assert event_id == failed.id
    assert {:error, :not_failed} = WebhookReplay.replay_failed(failed.id, actor: admin)
    assert length(process_webhook_jobs(failed.id)) == 1
  end

  defmodule FailingEnqueue do
    @moduledoc false
    def enqueue_processing_once(_event), do: {:error, :enqueue_failed}
  end

  defmodule FailingAudit do
    @moduledoc false
    def webhook_replay_requested(_attrs), do: {:error, :audit_down}
  end

  defp failed_event!(source, attrs \\ []) do
    attrs = Map.new(attrs)
    {:ok, event} = create_event(source, Map.drop(attrs, [:processing_attempt_count]))

    event =
      Ash.update!(
        event,
        %{
          processing_attempt_count: Map.get(attrs, :processing_attempt_count, 2),
          processing_started_at: ~U[2026-05-18 08:01:00Z]
        },
        action: :mark_processing,
        domain: Ingestion
      )

    Ash.update!(
      event,
      %{
        failed_at: ~U[2026-05-18 08:02:00Z],
        error_message: "permanent failure"
      },
      action: :mark_failed,
      domain: Ingestion
    )
  end

  defp create_event(source, attrs \\ %{}) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: "replay-delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "hash-#{System.unique_integer([:positive])}",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: ~U[2026-05-01 08:05:00Z],
      sanitized_headers_snapshot: %{}
    }

    WebhookEventStore.create_receive(Map.merge(defaults, attrs))
  end

  defp process_webhook_jobs(event_id) do
    all_enqueued(worker: ProcessWebhookWorker)
    |> Enum.filter(&(&1.args["webhook_event_id"] == event_id))
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Test User",
        password: password,
        password_confirmation: password
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
