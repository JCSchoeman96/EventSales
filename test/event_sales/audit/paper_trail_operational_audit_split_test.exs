defmodule EventSales.Audit.PaperTrailOperationalAuditSplitTest do
  use EventSales.DataCase, async: false

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.EventAccessGrant
  alias EventSales.Accounts.Resources.User
  alias EventSales.Audit
  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Audit.MetadataSanitizer
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.Resources.TicketType

  @event_id "11111111-1111-1111-1111-111111111111"

  test "product mapping update creates a paper trail version" do
    ctx = mapping_context!()
    mapping = create_mapping!(ctx, %{woo_product_id: 400, woo_variation_id: nil})

    updated = Ash.update!(mapping, %{current_label: "After"}, action: :update, domain: Catalog)

    loaded = Ash.load!(updated, :paper_trail_versions, domain: Catalog)
    assert length(loaded.paper_trail_versions) == 1
  end

  test "event access grant update and revoke create paper trail versions" do
    user = create_user!("audit-grant@example.com")
    grant = create_event_grant!(user, @event_id, :event_staff)

    updated =
      Ash.update!(
        grant,
        %{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)},
        action: :update,
        domain: Accounts
      )

    revoked = Ash.update!(updated, %{}, action: :revoke, domain: Accounts)

    loaded = Ash.load!(revoked, :paper_trail_versions, domain: Accounts)
    assert length(loaded.paper_trail_versions) == 2
    assert Enum.map(loaded.paper_trail_versions, & &1.version_action_name) == [:update, :revoke]
  end

  test "operational logger APIs write sanitized audit logs" do
    user = create_user!("audit-actor@example.com")

    assert {:ok, manual_sync} =
             AuditLogger.manual_sync_requested(%{
               actor_type: :user,
               actor_user_id: user.id,
               actor_role: :admin,
               source: :admin,
               subject_type: "sync_run",
               subject_id: "sync-123",
               event_id: @event_id,
               metadata: %{scope: "event", consumer_secret: "hidden"}
             })

    assert {:ok, csv_apply} =
             AuditLogger.csv_apply_requested(%{
               actor_type: :worker,
               actor_role: :staff,
               source: :csv,
               subject_type: "csv_import_batch",
               subject_id: "batch-123",
               event_id: @event_id,
               metadata: %{rows_applied: 10}
             })

    assert {:ok, replay} =
             AuditLogger.webhook_replay_requested(%{
               actor_type: :user,
               actor_user_id: user.id,
               actor_role: :admin,
               source: :admin,
               subject_type: "webhook_event",
               subject_id: "webhook-123",
               metadata: %{delivery_id: "delivery-123", raw_body: "{\"secret\":true}"}
             })

    assert manual_sync.event_type == :manual_sync_requested
    assert manual_sync.metadata == %{"scope" => "event"}
    assert csv_apply.event_type == :csv_apply_requested
    assert csv_apply.metadata == %{"rows_applied" => 10}
    assert replay.event_type == :webhook_replay_requested
    refute Map.has_key?(replay.metadata, "raw_body")
  end

  test "webhook operational logger APIs write audit logs" do
    assert {:ok, ignored} =
             AuditLogger.log_webhook_replay_ignored(%{
               actor_type: :webhook,
               source: :webhook,
               subject_type: "webhook_event",
               subject_id: "webhook-ignored",
               metadata: %{reason: "already_processed"}
             })

    assert {:ok, mismatch} =
             AuditLogger.log_webhook_duplicate_payload_mismatch(%{
               actor_type: :webhook,
               source: :webhook,
               subject_type: "webhook_event",
               subject_id: "webhook-mismatch",
               metadata: %{delivery_id: "dup-1", signature: "hidden"}
             })

    assert {:ok, stale} =
             AuditLogger.log_webhook_stale_replay(%{
               actor_type: :webhook,
               source: :webhook,
               subject_type: "webhook_event",
               subject_id: "webhook-stale",
               metadata: %{incoming_updated_at: "2026-01-01T00:00:00Z"}
             })

    assert ignored.event_type == :webhook_replay_ignored
    assert mismatch.event_type == :webhook_duplicate_payload_mismatch
    refute Map.has_key?(mismatch.metadata, "signature")
    assert stale.event_type == :webhook_stale_replay
  end

  test "audit log enum constraints reject invalid values" do
    valid = %{
      event_type: :manual_sync_requested,
      actor_type: :system,
      source: :system,
      metadata: %{},
      occurred_at: DateTime.utc_now()
    }

    for {field, value} <- [
          event_type: :made_up_event,
          actor_type: :made_up_actor,
          actor_role: :made_up_role,
          source: :made_up_source
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               AuditLog
               |> Ash.Changeset.for_create(:log, Map.put(valid, field, value))
               |> Ash.create(domain: Audit)
    end
  end

  test "logger rejects non-map metadata without coercion" do
    assert {:error, :invalid_metadata} =
             AuditLogger.manual_sync_requested(%{
               actor_type: :system,
               source: :system,
               metadata: "not a map"
             })

    assert {:error, :invalid_metadata} =
             AuditLogger.csv_apply_requested(%{
               actor_type: :system,
               source: :csv,
               metadata: [:not, :a, :map]
             })
  end

  test "metadata sanitizer removes sensitive keys recursively and bounds encoded size" do
    metadata = %{
      :safe => "keep",
      "Headers" => %{"Authorization" => "Bearer token", "x-wc-webhook-signature" => "sig"},
      :nested => [
        %{email: "person@example.test", line_items: [%{name: "GA"}]},
        %{"billing" => %{"first_name" => "A", "phone" => "123"}}
      ],
      :payload => %{"anything" => "removed"}
    }

    assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)

    assert sanitized == %{
             "nested" => [%{"line_items" => [%{"name" => "GA"}]}, %{}],
             "safe" => "keep"
           }

    huge = %{safe: String.duplicate("x", 5_000), nested: %{safe: String.duplicate("y", 5_000)}}

    assert {:ok, bounded} = MetadataSanitizer.sanitize(huge)
    assert bounded["metadata_truncated"] == true
    assert {:ok, encoded} = Jason.encode(bounded)
    assert byte_size(encoded) <= 2048
  end

  test "request context hashes are omitted without salt and HMAC-derived with salt" do
    original = Application.get_env(:event_sales, :audit_hash_salt)
    on_exit(fn -> Application.put_env(:event_sales, :audit_hash_salt, original) end)

    Application.delete_env(:event_sales, :audit_hash_salt)

    assert {:ok, no_hashes} =
             AuditLogger.manual_sync_requested(%{
               actor_type: :system,
               source: :system,
               metadata: %{},
               ip: "192.0.2.10",
               user_agent: "Mozilla/5.0"
             })

    assert no_hashes.ip_hash == nil
    assert no_hashes.user_agent_hash == nil

    Application.put_env(:event_sales, :audit_hash_salt, "test-audit-salt")

    assert {:ok, hashed} =
             AuditLogger.manual_sync_requested(%{
               actor_type: :system,
               source: :system,
               metadata: %{},
               ip: "192.0.2.10",
               user_agent: "Mozilla/5.0"
             })

    assert hashed.ip_hash == hmac("test-audit-salt", "192.0.2.10")
    assert hashed.user_agent_hash == hmac("test-audit-salt", "Mozilla/5.0")
  end

  test "caller-provided request hashes are ignored" do
    original = Application.get_env(:event_sales, :audit_hash_salt)
    on_exit(fn -> Application.put_env(:event_sales, :audit_hash_salt, original) end)

    Application.delete_env(:event_sales, :audit_hash_salt)

    assert {:ok, no_salt} =
             AuditLogger.manual_sync_requested(%{
               actor_type: :system,
               source: :system,
               metadata: %{},
               ip_hash: "192.0.2.10",
               user_agent_hash: "raw browser string"
             })

    assert no_salt.ip_hash == nil
    assert no_salt.user_agent_hash == nil

    Application.put_env(:event_sales, :audit_hash_salt, "test-audit-salt")

    assert {:ok, with_salt} =
             AuditLogger.manual_sync_requested(%{
               actor_type: :system,
               source: :system,
               metadata: %{},
               ip: "192.0.2.10",
               user_agent: "Mozilla/5.0",
               ip_hash: "attacker supplied ip hash",
               user_agent_hash: "attacker supplied user agent hash"
             })

    assert with_salt.ip_hash == hmac("test-audit-salt", "192.0.2.10")
    assert with_salt.user_agent_hash == hmac("test-audit-salt", "Mozilla/5.0")
  end

  test "audit resources and AshAdmin visibility are intentional" do
    assert EventSales.Audit.Resources.AuditLog in Ash.Domain.Info.resources(Audit)
    refute AshAdmin.Domain.show?(Audit)

    assert EventSales.Accounts.Resources.EventAccessGrant.Version in Ash.Domain.Info.resources(
             Accounts
           )

    refute EventSales.Accounts.Resources.EventAccessGrant.Version in AshAdmin.Domain.show_resources(
             Accounts
           )
  end

  defp hmac(salt, value) do
    :hmac
    |> :crypto.mac(:sha256, salt, value)
    |> Base.encode16(case: :lower)
  end

  defp mapping_context! do
    source = create_source_system!()
    event = create_event!(source, %{name: "Mapped Event", slug: "mapped-event"})
    ticket = create_ticket_type!(event, %{name: "GA"})
    %{source: source, event: event, ticket: ticket}
  end

  defp create_source_system!(attrs \\ %{}) do
    defaults = %{
      name: "Woo Store",
      kind: :woocommerce,
      base_url: "https://store-#{System.unique_integer([:positive])}.example.test"
    }

    Ash.create!(SourceSystem, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_event!(source, attrs) do
    defaults = %{
      source_system_id: source.id,
      name: "Event",
      slug: "event-#{System.unique_integer([:positive])}",
      status: :active
    }

    Ash.create!(Event, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_ticket_type!(event, attrs) do
    defaults = %{event_id: event.id, name: "Ticket", active: true}
    Ash.create!(TicketType, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_mapping!(%{source: source, event: event, ticket: ticket}, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Label",
      current_label: "Label",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
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

  defp create_event_grant!(user, event_id, role, opts \\ []) do
    attrs =
      %{
        user_id: user.id,
        event_id: event_id,
        role: role
      }
      |> Map.merge(Map.new(opts))

    Ash.create!(EventAccessGrant, attrs, action: :create, domain: Accounts)
  end
end
