defmodule EventSales.Ingestion.HistoricalCatchupEvidence do
  @moduledoc """
  Bounded, durable evidence for the immutable historical catch-up manifest.

  Catch-up evidence stores only the child manifest identity, its source
  high-water timestamp, and one bounded continuation proof. It deliberately
  does not store page items, identity arrays, or a duplicate of the parent
  manifest binding.
  """

  alias EventSales.Ingestion.Clients.WooOrderIndexClient.Page
  alias EventSales.Ingestion.HistoricalManifestEvidence

  @metadata_key "historical_catchup"
  @schema_version "2026-08-13.catchup.v1"
  @phase "catch_up"
  @pending_state "pending_first_page"
  @claim_state "create_claimed"
  @in_progress_state "catchup_in_progress"
  @terminal_state "catchup_terminal"
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
          :invalid_catchup_evidence
          | :invalid_catchup_page
          | :catchup_manifest_expired
          | :invalid_now
          | :metadata_too_large
          | :metadata_not_json_encodable
          | :invalid_parent_manifest
          | :catchup_high_water_before_parent
          | :catchup_continuity_mismatch

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

  @doc "Returns the minimal durable metadata for an authorized catch-up POST."
  @spec claim_metadata() :: %{String.t() => map()}
  def claim_metadata, do: %{@metadata_key => %{"state" => @claim_state}}

  @doc "Classifies the catch-up namespace without performing I/O."
  @spec state(map()) ::
          :missing
          | :create_claimed
          | :pending_first_page
          | :catchup_in_progress
          | :catchup_terminal
          | :corrupt
  def state(metadata) when is_map(metadata) do
    case Map.fetch(metadata, @metadata_key) do
      :error -> if Map.has_key?(metadata, :historical_catchup), do: :corrupt, else: :missing
      {:ok, raw} -> namespace_state(raw)
    end
  end

  def state(_metadata), do: :corrupt

  defp namespace_state(%{"state" => @claim_state} = raw)
       when raw == %{"state" => @claim_state},
       do: :create_claimed

  defp namespace_state(raw) when is_map(raw) do
    case raw["state"] do
      @pending_state ->
        if valid_pending_namespace?(raw), do: :pending_first_page, else: :corrupt

      @in_progress_state ->
        if valid_in_progress_namespace?(raw), do: :catchup_in_progress, else: :corrupt

      @terminal_state ->
        if valid_terminal_namespace?(raw), do: :catchup_terminal, else: :corrupt

      _other ->
        :corrupt
    end
  end

  defp namespace_state(_raw), do: :corrupt

  @doc "Builds child evidence from one validated catch-up page and terminal M."
  @spec from_page(Page.t() | map(), HistoricalManifestEvidence.t()) ::
          {:ok, t()} | {:error, reason()}
  def from_page(page, %HistoricalManifestEvidence{} = parent) do
    with {:ok, parent} <- validate_parent(parent),
         {:ok, fields} <- page_fields(page),
         :ok <- validate_page_fields(fields),
         {:ok, manifest_expires_at} <- utc_datetime(fields.manifest_expires_at),
         {:ok, source_observed_at} <- utc_datetime(fields.source_observed_at),
         :ok <- validate_child_boundary(fields.boundary_token, parent.boundary_token),
         :ok <- validate_high_water(source_observed_at, parent.source_observed_at) do
      {:ok, build_evidence(fields, manifest_expires_at, source_observed_at, @pending_state)}
    else
      {:error, reason}
      when reason in [:invalid_parent_manifest, :catchup_high_water_before_parent] ->
        {:error, reason}

      _error ->
        {:error, :invalid_catchup_page}
    end
  end

  def from_page(_page, _parent), do: {:error, :invalid_parent_manifest}

  @doc "Parses and strictly validates one legal child metadata namespace."
  @spec from_metadata(map()) :: {:ok, t()} | {:error, reason()}
  def from_metadata(metadata) when is_map(metadata) do
    with {:ok, raw} <- fetch_namespace(metadata),
         :ok <- validate_evidence_keys(raw),
         :ok <- validate_common_values(raw),
         {:ok, manifest_expires_at} <- utc_wire_datetime(raw["manifest_expires_at_gmt"]),
         {:ok, source_observed_at} <- utc_wire_datetime(raw["source_observed_at_gmt"]),
         :ok <- validate_state_values(raw) do
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
      _error -> {:error, :invalid_catchup_evidence}
    end
  end

  def from_metadata(_metadata), do: {:error, :invalid_catchup_evidence}

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

    %{
      @metadata_key => %{
        "schema_version" => namespace["schema_version"],
        "phase" => namespace["phase"],
        "boundary_token" => namespace["boundary_token"],
        "manifest_hash" => namespace["manifest_hash"],
        "manifest_expires_at_gmt" => namespace["manifest_expires_at_gmt"],
        "source_observed_at_gmt" => namespace["source_observed_at_gmt"],
        "state" => namespace["state"]
      }
    }
    |> put_optional_metadata(namespace, "next_cursor")
    |> put_optional_metadata(namespace, "terminal_evidence")
  end

  @doc "Builds the exact in-progress metadata state for a persisted U cursor."
  @spec in_progress_metadata(t(), String.t()) :: %{String.t() => map()}
  def in_progress_metadata(%__MODULE__{} = evidence, next_cursor) when is_binary(next_cursor) do
    %{evidence | state: @in_progress_state, next_cursor: next_cursor, terminal_evidence: nil}
    |> metadata()
  end

  @doc "Builds the exact terminal metadata state for an explicit U proof."
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

  @doc "Merges child evidence into the durable metadata and enforces 2048 bytes."
  @spec canonical_metadata(map(), t()) ::
          {:ok, map()} | {:error, :metadata_too_large | :metadata_not_json_encodable}
  def canonical_metadata(metadata, %__MODULE__{} = evidence) when is_map(metadata) do
    candidate = Map.merge(metadata, metadata(evidence))

    case encoded_size(candidate) do
      {:ok, size} when size <= @metadata_max_bytes -> {:ok, candidate}
      {:ok, _size} -> {:error, :metadata_too_large}
      {:error, _reason} -> {:error, :metadata_not_json_encodable}
    end
  end

  def canonical_metadata(_metadata, _evidence), do: {:error, :metadata_not_json_encodable}

  @doc "Returns the durable metadata byte maximum."
  @spec metadata_max_bytes() :: pos_integer()
  def metadata_max_bytes, do: @metadata_max_bytes

  @doc "Validates that child evidence remains unexpired at now."
  @spec validate_unexpired(t(), DateTime.t()) :: :ok | {:error, reason()}
  def validate_unexpired(%__MODULE__{} = evidence, now) do
    case utc_datetime(now) do
      {:ok, now} ->
        if DateTime.compare(now, evidence.manifest_expires_at) == :lt,
          do: :ok,
          else: {:error, :catchup_manifest_expired}

      _error ->
        {:error, :invalid_now}
    end
  end

  @doc "Validates the terminal parent authority used by a catch-up child."
  @spec validate_parent(HistoricalManifestEvidence.t()) ::
          {:ok, HistoricalManifestEvidence.t()} | {:error, :invalid_parent_manifest}
  def validate_parent(%HistoricalManifestEvidence{} = parent) do
    with true <- parent.state == "manifest_terminal",
         true <- is_nil(parent.next_cursor),
         {:ok, parsed} <- HistoricalManifestEvidence.from_metadata(parent_metadata(parent)),
         true <- parsed.state == "manifest_terminal" do
      {:ok, parsed}
    else
      _error -> {:error, :invalid_parent_manifest}
    end
  end

  def validate_parent(_parent), do: {:error, :invalid_parent_manifest}

  @doc "Validates child binding to the exact terminal parent authority."
  @spec validate_parent_binding(t(), HistoricalManifestEvidence.t()) ::
          :ok | {:error, :invalid_parent_manifest | :invalid_catchup_evidence | reason()}
  def validate_parent_binding(%__MODULE__{} = child, %HistoricalManifestEvidence{} = parent) do
    with true <- child.state in [@pending_state, @in_progress_state, @terminal_state],
         {:ok, _child} <- from_metadata(metadata(child)),
         {:ok, parent} <- validate_parent(parent),
         :ok <- validate_child_boundary(child.boundary_token, parent.boundary_token),
         :ok <- validate_high_water(child.source_observed_at, parent.source_observed_at) do
      :ok
    else
      {:error, :catchup_high_water_before_parent} = error -> error
      {:error, :invalid_parent_manifest} = error -> error
      _error -> {:error, :invalid_catchup_evidence}
    end
  end

  def validate_parent_binding(_child, _parent), do: {:error, :invalid_parent_manifest}

  @doc "Validates the immutable child identity on one later U page."
  @spec validate_continuity(t(), Page.t() | map()) ::
          :ok | {:error, :catchup_continuity_mismatch}
  def validate_continuity(%__MODULE__{} = evidence, page) when is_map(page) do
    with {:ok, page_evidence} <- page_evidence(page),
         true <- same_identity?(evidence, page_evidence) do
      :ok
    else
      _error -> {:error, :catchup_continuity_mismatch}
    end
  end

  def validate_continuity(_evidence, _page),
    do: {:error, :catchup_continuity_mismatch}

  defp parent_metadata(parent) do
    HistoricalManifestEvidence.metadata(parent)
  end

  defp fetch_namespace(metadata) do
    case Map.fetch(metadata, @metadata_key) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      _other -> {:error, :invalid_catchup_evidence}
    end
  end

  defp valid_pending_namespace?(raw) do
    with :ok <- validate_evidence_keys(raw),
         :ok <- validate_common_values(raw),
         {:ok, _expires_at} <- utc_wire_datetime(raw["manifest_expires_at_gmt"]),
         {:ok, _observed_at} <- utc_wire_datetime(raw["source_observed_at_gmt"]),
         :ok <- validate_state_values(raw) do
      true
    else
      _error -> false
    end
  end

  defp valid_in_progress_namespace?(raw), do: valid_namespace?(raw, @in_progress_state)
  defp valid_terminal_namespace?(raw), do: valid_namespace?(raw, @terminal_state)

  defp valid_namespace?(raw, expected_state) do
    with :ok <- validate_evidence_keys(raw),
         :ok <- validate_common_values(raw),
         {:ok, _expires_at} <- utc_wire_datetime(raw["manifest_expires_at_gmt"]),
         {:ok, _observed_at} <- utc_wire_datetime(raw["source_observed_at_gmt"]),
         true <- raw["state"] == expected_state,
         :ok <- validate_state_values(raw) do
      true
    else
      _error -> false
    end
  end

  defp validate_common_values(raw) do
    if raw["schema_version"] == @schema_version and
         raw["phase"] == @phase and
         valid_boundary_token?(raw["boundary_token"]) and
         valid_manifest_hash?(raw["manifest_hash"]),
       do: :ok,
       else: :error
  end

  defp validate_evidence_keys(raw) do
    case raw["state"] do
      @pending_state -> keys_match(raw, @evidence_keys)
      @in_progress_state -> keys_match(raw, @in_progress_keys)
      @terminal_state -> keys_match(raw, @terminal_keys)
      _other -> :error
    end
  end

  defp validate_state_values(%{"state" => @pending_state}), do: :ok

  defp validate_state_values(%{"state" => @in_progress_state, "next_cursor" => cursor}) do
    if valid_cursor?(cursor), do: :ok, else: :error
  end

  defp validate_state_values(%{"state" => @terminal_state, "terminal_evidence" => evidence}) do
    if valid_terminal_evidence?(evidence), do: :ok, else: :error
  end

  defp validate_state_values(_raw), do: :error

  defp page_fields(page) when is_struct(page, Page) do
    page = Map.from_struct(page)

    {:ok,
     %{
       schema_version: page.schema_version,
       phase: page.phase,
       boundary_token: page.boundary_token,
       manifest_hash: page.manifest_hash,
       manifest_expires_at: page.manifest_expires_at,
       source_observed_at: page.source_observed_at,
       items: page.items,
       has_more: page.has_more,
       next_cursor: page.next_cursor,
       terminal_evidence: page.terminal_evidence
     }}
  end

  defp page_fields(page) when is_map(page) do
    keys = Map.keys(page)

    if valid_page_keys?(keys) do
      {:ok,
       %{
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
       }}
    else
      {:error, :invalid_catchup_page}
    end
  end

  defp page_fields(_page), do: {:error, :invalid_catchup_page}

  defp valid_page_keys?(keys) do
    keys = Enum.map(keys, &wire_key/1)

    expected_keys = [
      [
        "schema_version",
        "phase",
        "boundary_token",
        "manifest_hash",
        "manifest_expires_at_gmt",
        "source_observed_at_gmt",
        "items",
        "has_more"
      ],
      [
        "schema_version",
        "phase",
        "boundary_token",
        "manifest_hash",
        "manifest_expires_at_gmt",
        "source_observed_at_gmt",
        "items",
        "has_more",
        "next_cursor"
      ],
      [
        "schema_version",
        "phase",
        "boundary_token",
        "manifest_hash",
        "manifest_expires_at_gmt",
        "source_observed_at_gmt",
        "items",
        "has_more",
        "terminal_evidence"
      ]
    ]

    Enum.all?(keys, &is_binary/1) and length(keys) == length(Enum.uniq(keys)) and
      Enum.any?(expected_keys, &MapSet.equal?(MapSet.new(keys), MapSet.new(&1)))
  end

  defp wire_key(value) when is_binary(value), do: value

  defp wire_key(value) when value in [:schema_version, :phase, :boundary_token],
    do: Atom.to_string(value)

  defp wire_key(:manifest_hash), do: "manifest_hash"
  defp wire_key(:manifest_expires_at), do: "manifest_expires_at_gmt"
  defp wire_key(:source_observed_at), do: "source_observed_at_gmt"
  defp wire_key(:items), do: "items"
  defp wire_key(:has_more), do: "has_more"
  defp wire_key(:next_cursor), do: "next_cursor"
  defp wire_key(:terminal_evidence), do: "terminal_evidence"
  defp wire_key(_value), do: nil

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
         true <- is_boolean(fields.has_more),
         :ok <- validate_paging(fields) do
      :ok
    else
      _error -> {:error, :invalid_catchup_page}
    end
  end

  defp validate_items(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      if valid_item?(item), do: {:cont, :ok}, else: {:halt, {:error, :invalid_catchup_page}}
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
    if valid_cursor?(cursor), do: :ok, else: {:error, :invalid_catchup_page}
  end

  defp validate_paging(%{has_more: false, next_cursor: nil, terminal_evidence: evidence})
       when is_binary(evidence) and byte_size(evidence) in 1..@max_opaque_evidence_bytes,
       do: :ok

  defp validate_paging(_fields), do: {:error, :invalid_catchup_page}

  defp page_evidence(page) do
    with {:ok, fields} <- page_fields(page),
         :ok <- validate_page_fields(fields),
         {:ok, manifest_expires_at} <- utc_datetime(fields.manifest_expires_at),
         {:ok, source_observed_at} <- utc_datetime(fields.source_observed_at) do
      {:ok, build_evidence(fields, manifest_expires_at, source_observed_at, @pending_state)}
    else
      _error -> {:error, :catchup_continuity_mismatch}
    end
  end

  defp build_evidence(fields, manifest_expires_at, source_observed_at, state) do
    %__MODULE__{
      schema_version: fields.schema_version,
      phase: fields.phase,
      boundary_token: fields.boundary_token,
      manifest_hash: fields.manifest_hash,
      manifest_expires_at: manifest_expires_at,
      source_observed_at: source_observed_at,
      state: state,
      next_cursor: nil,
      terminal_evidence: nil
    }
  end

  defp put_optional_metadata(metadata, namespace, key) do
    if Map.has_key?(namespace, key),
      do: put_in(metadata, [@metadata_key, key], namespace[key]),
      else: metadata
  end

  defp validate_child_boundary(child, parent)
       when is_binary(child) and is_binary(parent) and child != parent do
    :ok
  end

  defp validate_child_boundary(_child, _parent), do: {:error, :invalid_catchup_page}

  defp validate_high_water(child, parent) do
    case {utc_datetime(child), utc_datetime(parent)} do
      {{:ok, child}, {:ok, parent}} ->
        if DateTime.compare(child, parent) in [:eq, :gt],
          do: :ok,
          else: {:error, :catchup_high_water_before_parent}

      _error ->
        {:error, :invalid_catchup_page}
    end
  end

  defp valid_boundary_token?(value)
       when is_binary(value) and byte_size(value) in 1..@max_boundary_token_bytes,
       do: Regex.match?(@boundary_token_regex, value)

  defp valid_boundary_token?(_value), do: false

  defp valid_manifest_hash?(value) when is_binary(value),
    do: Regex.match?(@manifest_hash_regex, value)

  defp valid_manifest_hash?(_value), do: false

  defp valid_cursor?(value)
       when is_binary(value) and byte_size(value) in 1..@max_opaque_evidence_bytes,
       do: Regex.match?(@cursor_regex, value)

  defp valid_cursor?(_value), do: false

  defp valid_terminal_evidence?(value)
       when is_binary(value) and byte_size(value) in 1..@max_opaque_evidence_bytes,
       do: true

  defp valid_terminal_evidence?(_value), do: false

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

  defp keys_match(raw, expected_keys) do
    if Enum.sort(Map.keys(raw)) == Enum.sort(expected_keys), do: :ok, else: :error
  end

  defp same_identity?(left, right) do
    left.schema_version == right.schema_version and
      left.phase == right.phase and
      left.boundary_token == right.boundary_token and
      left.manifest_hash == right.manifest_hash and
      DateTime.compare(left.manifest_expires_at, right.manifest_expires_at) == :eq and
      DateTime.compare(left.source_observed_at, right.source_observed_at) == :eq
  end
end
