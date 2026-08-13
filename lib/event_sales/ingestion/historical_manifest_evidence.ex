defmodule EventSales.Ingestion.HistoricalManifestEvidence do
  @moduledoc """
  Bounded, durable evidence for the immutable Woo order-index manifest.

  This module deliberately stores manifest identity and source-bound timestamps
  only. It never stores manifest items or source order/customer data.
  """

  alias EventSales.Ingestion.Clients.WooOrderIndexClient.Page

  @metadata_key "historical_manifest"
  @schema_version "2026-08-12.v1"
  @phase "manifest_enumerate"
  @pending_state "pending_first_page"
  @claim_state "create_claimed"
  @in_progress_state "manifest_in_progress"
  @terminal_state "manifest_terminal"
  @metadata_max_bytes 2048
  @max_boundary_token_bytes 128
  @max_opaque_evidence_bytes 512
  @max_page_items 100
  @boundary_token_regex ~r/\A[A-Za-z0-9._-]+\z/
  @cursor_regex ~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/
  @positive_decimal_regex ~r/\A[1-9][0-9]*\z/
  @manifest_hash_regex ~r/\A[0-9a-f]{64}\z/
  @utc_wire_regex ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\z/

  @evidence_keys [
    "schema_version",
    "phase",
    "boundary_token",
    "manifest_hash",
    "manifest_expires_at_gmt",
    "source_observed_at_gmt",
    "state"
  ]

  @in_progress_keys @evidence_keys ++ ["next_cursor"]
  @terminal_keys @evidence_keys ++ ["terminal_evidence"]

  @type t :: %__MODULE__{
          schema_version: String.t(),
          phase: String.t(),
          boundary_token: String.t(),
          manifest_hash: String.t(),
          manifest_expires_at: DateTime.t(),
          source_observed_at: DateTime.t(),
          state: String.t(),
          next_cursor: String.t() | nil,
          terminal_evidence: String.t() | nil
        }

  @type reason ::
          :invalid_manifest_evidence
          | :invalid_manifest_page
          | :manifest_expired
          | :invalid_now
          | :metadata_too_large
          | :metadata_not_json_encodable
          | :manifest_continuity_mismatch

  defstruct [
    :schema_version,
    :phase,
    :boundary_token,
    :manifest_hash,
    :manifest_expires_at,
    :source_observed_at,
    :state,
    :next_cursor,
    :terminal_evidence
  ]

  @doc "Returns the stable top-level metadata namespace used by this evidence."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc "Returns the minimal durable metadata for an authorized create attempt."
  @spec claim_metadata() :: %{String.t() => map()}
  def claim_metadata, do: %{@metadata_key => %{"state" => @claim_state}}

  @doc "Classifies the historical manifest namespace without performing I/O."
  @spec state(map()) ::
          :missing
          | :create_claimed
          | :pending_first_page
          | :manifest_in_progress
          | :manifest_terminal
          | :corrupt
  def state(metadata) when is_map(metadata) do
    case Map.fetch(metadata, @metadata_key) do
      :error -> missing_state(metadata)
      {:ok, raw} -> namespace_state(raw)
    end
  end

  def state(_metadata), do: :corrupt

  defp missing_state(metadata) do
    if Map.has_key?(metadata, :historical_manifest), do: :corrupt, else: :missing
  end

  defp namespace_state(%{"state" => @claim_state} = raw)
       when raw == %{"state" => @claim_state},
       do: :create_claimed

  defp namespace_state(raw) when is_map(raw), do: known_state(Map.get(raw, "state"))
  defp namespace_state(_raw), do: :corrupt

  defp known_state(@pending_state), do: :pending_first_page
  defp known_state(@in_progress_state), do: :manifest_in_progress
  defp known_state(@terminal_state), do: :manifest_terminal
  defp known_state(_state), do: :corrupt

  @doc "Builds evidence from one validated or validation-compatible source page."
  @spec from_page(Page.t() | map()) :: {:ok, t()} | {:error, reason()}
  def from_page(page), do: from_page(page, [])

  @spec from_page(Page.t() | map(), keyword()) :: {:ok, t()} | {:error, reason()}
  def from_page(page, _opts) when is_map(page) do
    with {:ok, fields} <- page_fields(page),
         :ok <- validate_page_fields(fields),
         {:ok, manifest_expires_at} <- utc_datetime(fields.manifest_expires_at),
         {:ok, source_observed_at} <- utc_datetime(fields.source_observed_at) do
      {:ok,
       %__MODULE__{
         schema_version: fields.schema_version,
         phase: fields.phase,
         boundary_token: fields.boundary_token,
         manifest_hash: fields.manifest_hash,
         manifest_expires_at: manifest_expires_at,
         source_observed_at: source_observed_at,
         state: @pending_state,
         next_cursor: nil,
         terminal_evidence: nil
       }}
    else
      _error -> {:error, :invalid_manifest_page}
    end
  end

  def from_page(_page, _opts), do: {:error, :invalid_manifest_page}

  @doc "Parses and strictly validates the complete cursor metadata map."
  @spec from_metadata(map()) :: {:ok, t()} | {:error, reason()}
  def from_metadata(metadata) when is_map(metadata) do
    with {:ok, raw} <- fetch_namespace(metadata),
         :ok <- validate_evidence_keys(raw),
         {:ok, manifest_expires_at} <- utc_wire_datetime(raw["manifest_expires_at_gmt"]),
         {:ok, source_observed_at} <- utc_wire_datetime(raw["source_observed_at_gmt"]),
         :ok <- validate_evidence_values(raw) do
      {:ok,
       %__MODULE__{
         schema_version: raw["schema_version"],
         phase: raw["phase"],
         boundary_token: raw["boundary_token"],
         manifest_hash: raw["manifest_hash"],
         manifest_expires_at: manifest_expires_at,
         source_observed_at: source_observed_at,
         state: raw["state"],
         next_cursor: raw["next_cursor"],
         terminal_evidence: raw["terminal_evidence"]
       }}
    else
      _error -> {:error, :invalid_manifest_evidence}
    end
  end

  def from_metadata(_metadata), do: {:error, :invalid_manifest_evidence}

  @doc "Returns the canonical nested metadata representation for durable storage."
  @spec metadata(t()) :: %{String.t() => map()}
  def metadata(%__MODULE__{} = evidence) do
    namespace = %{
      "schema_version" => evidence.schema_version,
      "phase" => evidence.phase,
      "boundary_token" => evidence.boundary_token,
      "manifest_hash" => evidence.manifest_hash,
      "manifest_expires_at_gmt" => DateTime.to_iso8601(evidence.manifest_expires_at),
      "source_observed_at_gmt" => DateTime.to_iso8601(evidence.source_observed_at),
      "state" => evidence.state
    }

    namespace =
      case evidence.state do
        @in_progress_state -> Map.put(namespace, "next_cursor", evidence.next_cursor)
        @terminal_state -> Map.put(namespace, "terminal_evidence", evidence.terminal_evidence)
        _other -> namespace
      end

    %{@metadata_key => namespace}
  end

  @doc "Builds the exact in-progress metadata state for a persisted source cursor."
  @spec in_progress_metadata(t(), String.t()) :: %{String.t() => map()}
  def in_progress_metadata(%__MODULE__{} = evidence, next_cursor)
      when is_binary(next_cursor) do
    %{evidence | state: @in_progress_state, next_cursor: next_cursor, terminal_evidence: nil}
    |> metadata()
  end

  @doc "Builds the exact terminal metadata state for a persisted source proof."
  @spec terminal_metadata(t(), String.t()) :: %{String.t() => map()}
  def terminal_metadata(%__MODULE__{} = evidence, terminal_evidence)
      when is_binary(terminal_evidence) do
    %{evidence | state: @terminal_state, next_cursor: nil, terminal_evidence: terminal_evidence}
    |> metadata()
  end

  @doc "Returns the encoded byte size of a JSON-encodable metadata map."
  @spec encoded_size(map()) :: {:ok, non_neg_integer()} | {:error, :not_json_encodable}
  def encoded_size(metadata) when is_map(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, _reason} -> {:error, :not_json_encodable}
    end
  end

  def encoded_size(_metadata), do: {:error, :not_json_encodable}

  @doc "Merges evidence into the durable namespace and enforces its byte bound."
  @spec canonical_metadata(map(), t()) ::
          {:ok, map()} | {:error, :metadata_too_large | :metadata_not_json_encodable}
  def canonical_metadata(metadata, %__MODULE__{} = evidence) when is_map(metadata) do
    metadata = Map.merge(metadata, __MODULE__.metadata(evidence))

    case encoded_size(metadata) do
      {:ok, size} when size <= @metadata_max_bytes -> {:ok, metadata}
      {:ok, _size} -> {:error, :metadata_too_large}
      {:error, _reason} -> {:error, :metadata_not_json_encodable}
    end
  end

  def canonical_metadata(_metadata, _evidence), do: {:error, :metadata_not_json_encodable}

  @doc "Adds a bounded failure summary without replacing historical manifest evidence."
  @spec with_failure(map(), String.t()) ::
          {:ok, map()} | {:error, :metadata_too_large | :metadata_not_json_encodable}
  def with_failure(metadata, failure) when is_map(metadata) and is_binary(failure) do
    candidate = Map.put(metadata, "failure", failure)

    case encoded_size(candidate) do
      {:ok, size} when size <= @metadata_max_bytes -> {:ok, candidate}
      {:ok, _size} -> {:error, :metadata_too_large}
      {:error, _reason} -> {:error, :metadata_not_json_encodable}
    end
  end

  def with_failure(_metadata, _failure), do: {:error, :metadata_not_json_encodable}

  @doc "Returns the durable metadata byte maximum."
  @spec metadata_max_bytes() :: pos_integer()
  def metadata_max_bytes, do: @metadata_max_bytes

  @doc "Validates that a newly captured manifest has not expired at now."
  @spec validate_unexpired(t(), DateTime.t()) :: :ok | {:error, reason()}
  def validate_unexpired(%__MODULE__{} = evidence, now) do
    case utc_datetime(now) do
      {:ok, now} ->
        if DateTime.compare(now, evidence.manifest_expires_at) == :lt do
          :ok
        else
          {:error, :manifest_expired}
        end

      _error ->
        {:error, :invalid_now}
    end
  end

  @doc """
  Proves that a later source page belongs to the same immutable manifest.

  The comparison covers every persisted identity/evidence field and performs
  no I/O.
  """
  @spec validate_continuity(t(), Page.t() | map()) ::
          :ok | {:error, :manifest_continuity_mismatch}
  def validate_continuity(%__MODULE__{} = evidence, page) when is_map(page) do
    case from_page(page) do
      {:ok, page_evidence} ->
        if same_identity?(evidence, page_evidence),
          do: :ok,
          else: {:error, :manifest_continuity_mismatch}

      {:error, _reason} ->
        {:error, :manifest_continuity_mismatch}
    end
  end

  def validate_continuity(_evidence, _page), do: {:error, :manifest_continuity_mismatch}

  defp fetch_namespace(metadata) do
    case Map.fetch(metadata, @metadata_key) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      _other -> {:error, :invalid_manifest_evidence}
    end
  end

  defp validate_evidence_keys(raw) do
    case raw["state"] do
      @pending_state -> keys_match?(raw, @evidence_keys)
      @in_progress_state -> keys_match?(raw, @in_progress_keys)
      @terminal_state -> keys_match?(raw, @terminal_keys)
      _other -> invalid_evidence()
    end
  end

  defp keys_match?(raw, expected_keys) do
    if Enum.sort(Map.keys(raw)) == Enum.sort(expected_keys),
      do: :ok,
      else: invalid_evidence()
  end

  defp validate_evidence_values(raw) do
    if valid_common_evidence_values?(raw),
      do: validate_state_values(raw),
      else: invalid_evidence()
  end

  defp valid_common_evidence_values?(raw) do
    raw["schema_version"] == @schema_version and
      raw["phase"] == @phase and
      valid_boundary_token?(raw["boundary_token"]) and
      valid_manifest_hash?(raw["manifest_hash"])
  end

  defp validate_state_values(%{"state" => @pending_state}), do: :ok

  defp validate_state_values(%{"state" => @in_progress_state, "next_cursor" => cursor}) do
    if valid_cursor?(cursor), do: :ok, else: invalid_evidence()
  end

  defp validate_state_values(%{"state" => @terminal_state, "terminal_evidence" => evidence}) do
    if valid_terminal_evidence?(evidence), do: :ok, else: invalid_evidence()
  end

  defp validate_state_values(_raw), do: invalid_evidence()
  defp invalid_evidence, do: {:error, :invalid_manifest_evidence}

  defp page_fields(page) do
    fields = %{
      schema_version: field(page, :schema_version, "schema_version"),
      phase: field(page, :phase, "phase"),
      boundary_token: field(page, :boundary_token, "boundary_token"),
      manifest_hash: field(page, :manifest_hash, "manifest_hash"),
      manifest_expires_at: field(page, :manifest_expires_at, "manifest_expires_at_gmt"),
      source_observed_at: field(page, :source_observed_at, "source_observed_at_gmt"),
      items: field(page, :items, "items"),
      has_more: field(page, :has_more, "has_more"),
      next_cursor: field(page, :next_cursor, "next_cursor"),
      terminal_evidence: field(page, :terminal_evidence, "terminal_evidence")
    }

    if Enum.any?(fields, fn {key, value} ->
         key not in [
           :manifest_expires_at,
           :source_observed_at,
           :next_cursor,
           :terminal_evidence
         ] and is_nil(value)
       end) do
      {:error, :invalid_manifest_page}
    else
      {:ok, fields}
    end
  end

  defp field(page, atom_key, string_key) do
    case Map.fetch(page, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(page, string_key)
    end
  end

  defp validate_page_fields(fields) do
    with true <- fields.schema_version == @schema_version,
         true <- fields.phase == @phase,
         true <- valid_boundary_token?(fields.boundary_token),
         true <- valid_manifest_hash?(fields.manifest_hash),
         true <- is_list(fields.items),
         true <- length(fields.items) <= @max_page_items,
         :ok <- validate_items(fields.items),
         :ok <- validate_paging(fields) do
      :ok
    else
      _error -> {:error, :invalid_manifest_page}
    end
  end

  defp validate_items(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      if valid_item?(item), do: {:cont, :ok}, else: {:halt, {:error, :invalid_manifest_page}}
    end)
  end

  defp valid_item?(item) when is_map(item) do
    MapSet.equal?(
      MapSet.new(Map.keys(item)),
      MapSet.new(["source_order_id", "source_created_at_gmt", "source_modified_at_gmt"])
    ) and
      is_binary(item["source_order_id"]) and
      Regex.match?(@positive_decimal_regex, item["source_order_id"]) and
      match?({:ok, _}, utc_wire_datetime(item["source_created_at_gmt"])) and
      match?({:ok, _}, utc_wire_datetime(item["source_modified_at_gmt"]))
  end

  defp valid_item?(_item), do: false

  defp validate_paging(%{has_more: true, next_cursor: cursor, terminal_evidence: nil})
       when is_binary(cursor) do
    if valid_cursor?(cursor), do: :ok, else: {:error, :invalid_manifest_page}
  end

  defp validate_paging(%{has_more: false, next_cursor: nil, terminal_evidence: evidence})
       when is_binary(evidence), do: validate_terminal_evidence(evidence)

  defp validate_paging(_fields), do: {:error, :invalid_manifest_page}

  defp valid_boundary_token?(value)
       when is_binary(value) and byte_size(value) in 1..@max_boundary_token_bytes do
    Regex.match?(@boundary_token_regex, value)
  end

  defp valid_boundary_token?(_value), do: false

  defp valid_manifest_hash?(value) when is_binary(value),
    do: Regex.match?(@manifest_hash_regex, value)

  defp valid_manifest_hash?(_value), do: false

  defp valid_cursor?(value)
       when is_binary(value) and byte_size(value) in 1..@max_opaque_evidence_bytes do
    Regex.match?(@cursor_regex, value)
  end

  defp valid_cursor?(_value), do: false

  defp valid_terminal_evidence?(value) when is_binary(value),
    do: validate_terminal_evidence(value) == :ok

  defp valid_terminal_evidence?(_value), do: false

  defp validate_terminal_evidence(value)
       when is_binary(value) and byte_size(value) in 1..@max_opaque_evidence_bytes,
       do: :ok

  defp validate_terminal_evidence(_value), do: {:error, :invalid_manifest_page}

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0,
      do: {:ok, value},
      else: {:error, :invalid_utc_datetime}
  end

  defp utc_datetime(value) when is_binary(value), do: utc_wire_datetime(value)
  defp utc_datetime(_value), do: {:error, :invalid_utc_datetime}

  defp utc_wire_datetime(value) when is_binary(value) do
    with true <- Regex.match?(@utc_wire_regex, value),
         {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         {:ok, datetime} <- utc_datetime(datetime),
         true <- DateTime.to_iso8601(datetime) == value do
      {:ok, datetime}
    else
      _error -> {:error, :invalid_utc_datetime}
    end
  end

  defp utc_wire_datetime(_value), do: {:error, :invalid_utc_datetime}

  defp same_identity?(left, right) do
    left.schema_version == right.schema_version and
      left.phase == right.phase and
      left.boundary_token == right.boundary_token and
      left.manifest_hash == right.manifest_hash and
      DateTime.compare(left.manifest_expires_at, right.manifest_expires_at) == :eq and
      DateTime.compare(left.source_observed_at, right.source_observed_at) == :eq
  end
end
