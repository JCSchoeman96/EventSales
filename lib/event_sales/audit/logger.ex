defmodule EventSales.Audit.Logger do
  @moduledoc """
  Public API for writing operational audit events.

  This module is intentionally thin: it sanitizes metadata, derives optional
  request-context hashes, and writes `EventSales.Audit.Resources.AuditLog`.
  Workflow modules call this boundary; this boundary does not implement those
  workflows.
  """

  alias EventSales.Audit
  alias EventSales.Audit.MetadataSanitizer
  alias EventSales.Audit.Resources.AuditLog

  @manual_mapping_metadata_keys ~w(
    source_system_id
    event_id
    ticket_type_id
    created_ticket_type
    woo_product_id
    woo_variation_id
    label
    source_status
    reason
  )

  @type attrs :: %{optional(atom()) => term()}
  @type result :: {:ok, AuditLog.t()} | {:error, term()}

  @doc "Writes a manual sync request audit event."
  @spec manual_sync_requested(attrs()) :: result()
  def manual_sync_requested(attrs), do: log(:manual_sync_requested, attrs)

  @doc "Writes a manual Tickera attendee snapshot sync request audit event."
  @spec tickera_attendee_sync_requested(attrs()) :: result()
  def tickera_attendee_sync_requested(attrs), do: log(:tickera_attendee_sync_requested, attrs)

  @doc "Writes a manual Tickera/Woo reconciliation run request audit event."
  @spec tickera_reconciliation_run_requested(attrs()) :: result()
  def tickera_reconciliation_run_requested(attrs),
    do: log(:tickera_reconciliation_run_requested, attrs)

  @doc "Writes a CSV apply request audit event."
  @spec csv_apply_requested(attrs()) :: result()
  def csv_apply_requested(attrs), do: log(:csv_apply_requested, attrs)

  @doc "Writes a manual product mapping creation audit event."
  @spec manual_mapping_created(attrs()) :: result()
  def manual_mapping_created(attrs) do
    log(
      :manual_mapping_created,
      Map.update(attrs, :metadata, %{}, &allow_manual_mapping_metadata/1)
    )
  end

  @doc "Writes an event sales export request audit event."
  @spec event_sales_export_requested(attrs()) :: result()
  def event_sales_export_requested(attrs), do: log(:event_sales_export_requested, attrs)

  @doc "Writes a webhook replay request audit event."
  @spec webhook_replay_requested(attrs()) :: result()
  def webhook_replay_requested(attrs), do: log(:webhook_replay_requested, attrs)

  @doc "Writes an audit event for an ignored webhook replay."
  @spec log_webhook_replay_ignored(attrs()) :: result()
  def log_webhook_replay_ignored(attrs), do: log(:webhook_replay_ignored, attrs)

  @doc "Writes an audit event for duplicate delivery IDs with mismatched payload hashes."
  @spec log_webhook_duplicate_payload_mismatch(attrs()) :: result()
  def log_webhook_duplicate_payload_mismatch(attrs),
    do: log(:webhook_duplicate_payload_mismatch, attrs)

  @doc "Writes an audit event for stale webhook replay detection."
  @spec log_webhook_stale_replay(attrs()) :: result()
  def log_webhook_stale_replay(attrs), do: log(:webhook_stale_replay, attrs)

  @doc """
  Writes an operational audit event.

  `attrs[:metadata]` must be a map. Non-map metadata is rejected and never
  coerced.
  """
  @spec log(atom(), attrs()) :: result()
  def log(event_type, attrs) when is_map(attrs) do
    metadata = Map.get(attrs, :metadata, %{})
    ash_opts = Map.get(attrs, :ash_opts, [])

    with {:ok, sanitized_metadata} <- MetadataSanitizer.sanitize(metadata) do
      attrs
      |> Map.drop([:ip, :user_agent, :ip_hash, :user_agent_hash, :ash_opts])
      |> Map.put(:event_type, event_type)
      |> Map.put_new(:occurred_at, DateTime.utc_now())
      |> Map.put(:metadata, sanitized_metadata)
      |> put_context_hashes(attrs)
      |> then(&Ash.create(AuditLog, &1, Keyword.merge([action: :log, domain: Audit], ash_opts)))
      |> normalize_result()
    end
  end

  def log(_event_type, _attrs), do: {:error, :invalid_attrs}

  defp allow_manual_mapping_metadata(metadata) when is_map(metadata) do
    metadata
    |> stringify_keys()
    |> Map.take(@manual_mapping_metadata_keys)
  end

  defp allow_manual_mapping_metadata(metadata), do: metadata

  defp stringify_keys(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_result({:ok, %AuditLog{} = audit_log, _notifications}), do: {:ok, audit_log}
  defp normalize_result(result), do: result

  defp put_context_hashes(audit_attrs, source_attrs) do
    salt = audit_hash_salt()

    audit_attrs
    |> maybe_put_hmac(:ip_hash, Map.get(source_attrs, :ip), salt)
    |> maybe_put_hmac(:user_agent_hash, Map.get(source_attrs, :user_agent), salt)
  end

  defp maybe_put_hmac(attrs, _field, _value, nil), do: attrs
  defp maybe_put_hmac(attrs, _field, nil, _salt), do: attrs
  defp maybe_put_hmac(attrs, _field, "", _salt), do: attrs

  defp maybe_put_hmac(attrs, field, value, salt) when is_binary(value) do
    Map.put(attrs, field, hmac(salt, value))
  end

  defp maybe_put_hmac(attrs, _field, _value, _salt), do: attrs

  defp audit_hash_salt do
    case Application.get_env(:event_sales, :audit_hash_salt) do
      salt when is_binary(salt) and byte_size(salt) > 0 -> salt
      _other -> nil
    end
  end

  defp hmac(salt, value) do
    :hmac
    |> :crypto.mac(:sha256, salt, value)
    |> Base.encode16(case: :lower)
  end
end
