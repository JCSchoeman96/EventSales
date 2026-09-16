defmodule EventSales.Ingestion.HistoricalCoverageEvidence do
  @moduledoc """
  Versioned, bounded evidence for a certified or blocked historical run.

  The evidence is deliberately aggregate-only. It contains source proof
  identities, bounded terminal proof strings, counters, and reason codes,
  never raw payloads, customer data, or per-ID ledgers.
  """

  @schema_version "2026-09-16.coverage.v1"
  @metadata_max_bytes 16_384
  @max_proof_bytes 2_048
  @max_reason_count 128
  @hash_regex ~r/\A[0-9a-f]{64}\z/
  @reason_regex ~r/\A[a-z][a-z0-9_]{0,95}\z/
  @top_level_keys [
    "schema_version",
    "manifest_hash",
    "manifest_terminal_evidence",
    "catchup_hash",
    "catchup_terminal_evidence",
    "orders",
    "refunds",
    "result",
    "evaluated_at"
  ]
  @order_keys [
    "manifest_members_seen",
    "orders_durable",
    "order_items_durable",
    "blocking_unresolved_count",
    "blocking_reasons"
  ]
  @refund_keys [
    "references_seen",
    "details_complete",
    "refund_lines_durable",
    "blocking_unresolved_count",
    "blocking_reasons"
  ]

  @type t :: %{String.t() => term()}
  @type result :: :certified | :blocked

  @doc "Returns the version of the persisted evidence schema."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc "Returns the maximum encoded evidence size in bytes."
  @spec metadata_max_bytes() :: pos_integer()
  def metadata_max_bytes, do: @metadata_max_bytes

  @doc "Builds and validates canonical string-keyed evidence."
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_map(attrs) do
    attrs =
      if Map.has_key?(attrs, "schema_version") or Map.has_key?(attrs, :schema_version),
        do: attrs,
        else: Map.put(attrs, :schema_version, @schema_version)

    canonicalize(attrs)
  end

  def build(_attrs), do: {:error, :invalid_evidence}

  @doc "Validates already-persisted evidence without changing its shape."
  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(evidence) when is_map(evidence), do: canonicalize(evidence)
  def validate(_evidence), do: {:error, :invalid_evidence}

  @doc "Returns true only for valid certified evidence."
  @spec certified?(term()) :: boolean()
  def certified?(evidence) do
    case validate(evidence) do
      {:ok, %{"result" => "certified"}} -> true
      _other -> false
    end
  end

  @doc "Returns true only for valid blocked evidence."
  @spec blocked?(term()) :: boolean()
  def blocked?(evidence) do
    case validate(evidence) do
      {:ok, %{"result" => "blocked"}} -> true
      _other -> false
    end
  end

  @doc "Returns a lowercase SHA-256 proof hash for a bounded binary value."
  @spec proof_hash(binary()) :: String.t() | nil
  def proof_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  def proof_hash(_value), do: nil

  defp canonicalize(attrs) do
    with {:ok, attrs} <- stringify_keys(attrs),
         :ok <- exact_keys(attrs, @top_level_keys),
         :ok <- validate_schema_version(attrs),
         {:ok, manifest_hash} <- hash(attrs["manifest_hash"], :manifest),
         {:ok, manifest_proof} <- proof(attrs["manifest_terminal_evidence"], :manifest),
         {:ok, catchup_hash} <- hash(attrs["catchup_hash"], :catchup),
         {:ok, catchup_proof} <- proof(attrs["catchup_terminal_evidence"], :catchup),
         {:ok, orders} <- section(attrs["orders"], "orders", @order_keys),
         {:ok, refunds} <- section(attrs["refunds"], "refunds", @refund_keys),
         {:ok, result} <- result(attrs["result"]),
         {:ok, evaluated_at} <- evaluated_at(attrs["evaluated_at"]) do
      evidence = %{
        "schema_version" => @schema_version,
        "manifest_hash" => manifest_hash,
        "manifest_terminal_evidence" => manifest_proof,
        "catchup_hash" => catchup_hash,
        "catchup_terminal_evidence" => catchup_proof,
        "orders" => orders,
        "refunds" => refunds,
        "result" => result,
        "evaluated_at" => evaluated_at
      }

      with :ok <- validate_result_consistency(evidence),
           :ok <- validate_encoded_size(evidence) do
        {:ok, evidence}
      end
    end
  end

  defp stringify_keys(map),
    do: Enum.reduce_while(map, {:ok, %{}}, &stringify_key_pair/2)

  defp stringify_key_pair({key, value}, {:ok, acc}) do
    case stringify_key(key) do
      {:ok, string_key} -> put_stringified_key(acc, string_key, value)
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp put_stringified_key(acc, key, value) do
    if Map.has_key?(acc, key),
      do: {:halt, {:error, {:duplicate_key, key}}},
      else: {:cont, {:ok, Map.put(acc, key, value)}}
  end

  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(_key), do: {:error, :invalid_key}

  defp exact_keys(map, expected_keys) do
    actual_keys = Map.keys(map)

    case Enum.sort(actual_keys -- expected_keys) do
      [unexpected | _rest] ->
        {:error, {:unexpected_key, unexpected}}

      [] ->
        case Enum.sort(expected_keys -- actual_keys) do
          [missing | _rest] -> {:error, {:missing_key, missing}}
          [] -> :ok
        end
    end
  end

  defp validate_schema_version(%{"schema_version" => @schema_version}), do: :ok
  defp validate_schema_version(_attrs), do: {:error, :invalid_schema_version}

  defp hash(value, _kind) when is_binary(value) do
    if Regex.match?(@hash_regex, value), do: {:ok, value}, else: {:error, :invalid_manifest_hash}
  end

  defp hash(_value, _kind), do: {:error, :invalid_manifest_hash}

  defp proof(value, _kind) when is_binary(value) do
    cond do
      value == "" -> {:error, :invalid_terminal_evidence}
      not String.valid?(value) -> {:error, :invalid_terminal_evidence}
      byte_size(value) > @max_proof_bytes -> {:error, :invalid_terminal_evidence}
      true -> {:ok, value}
    end
  end

  defp proof(_value, _kind), do: {:error, :invalid_terminal_evidence}

  defp section(value, name, expected_keys) when is_map(value) do
    with {:ok, value} <- stringify_keys(value),
         :ok <- section_keys(value, name, expected_keys),
         {:ok, counters} <- counters(value, name, expected_keys -- ["blocking_reasons"]),
         {:ok, reasons} <- reasons(value["blocking_reasons"], name),
         :ok <- reason_count_matches?(counters["blocking_unresolved_count"], reasons, name) do
      {:ok, Map.merge(counters, %{"blocking_reasons" => reasons})}
    end
  end

  defp section(_value, name, _expected_keys), do: {:error, {:invalid_section, name}}

  defp section_keys(value, name, expected_keys) do
    case exact_keys(value, expected_keys) do
      :ok -> :ok
      {:error, {:missing_key, key}} -> {:error, {:missing_key, name <> "." <> key}}
      {:error, {:unexpected_key, key}} -> {:error, {:unexpected_key, name <> "." <> key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp counters(value, name, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case value[key] do
        count when is_integer(count) and count >= 0 ->
          {:cont, {:ok, Map.put(acc, key, count)}}

        _other ->
          {:halt, {:error, {:invalid_counter, name <> "." <> key}}}
      end
    end)
  end

  defp reasons(value, name) when is_map(value) do
    with {:ok, value} <- stringify_keys(value),
         true <- map_size(value) <= @max_reason_count do
      Enum.reduce_while(value, {:ok, %{}}, fn pair, acc ->
        validate_reason(pair, acc, name)
      end)
    else
      false -> {:error, {:too_many_reason_codes, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reasons(_value, name), do: {:error, {:invalid_reasons, name}}

  defp validate_reason({key, count}, {:ok, acc}, name) do
    cond do
      not Regex.match?(@reason_regex, key) ->
        {:halt, {:error, {:invalid_reason_code, name <> ".blocking_reasons." <> key}}}

      not (is_integer(count) and count >= 0) ->
        {:halt, {:error, {:invalid_reason_count, name <> ".blocking_reasons." <> key}}}

      true ->
        {:cont, {:ok, Map.put(acc, key, count)}}
    end
  end

  defp reason_count_matches?(count, reasons, name) do
    if count == Enum.sum(Map.values(reasons)),
      do: :ok,
      else: {:error, {:blocking_count_mismatch, name}}
  end

  defp result("certified"), do: {:ok, "certified"}
  defp result("blocked"), do: {:ok, "blocked"}
  defp result(:certified), do: {:ok, "certified"}
  defp result(:blocked), do: {:ok, "blocked"}
  defp result(_result), do: {:error, :invalid_result}

  defp evaluated_at(%DateTime{} = value) do
    if utc_datetime?(value),
      do: {:ok, DateTime.to_iso8601(value)},
      else: {:error, :invalid_evaluated_at}
  end

  defp evaluated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> evaluated_at(parsed)
      _other -> {:error, :invalid_evaluated_at}
    end
  end

  defp evaluated_at(_value), do: {:error, :invalid_evaluated_at}

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp validate_result_consistency(%{
         "result" => "certified",
         "orders" => orders,
         "refunds" => refunds
       }) do
    if orders["blocking_unresolved_count"] == 0 and refunds["blocking_unresolved_count"] == 0,
      do: :ok,
      else: {:error, :certified_with_blocking_reasons}
  end

  defp validate_result_consistency(%{
         "result" => "blocked",
         "orders" => orders,
         "refunds" => refunds
       }) do
    if orders["blocking_unresolved_count"] > 0 or refunds["blocking_unresolved_count"] > 0,
      do: :ok,
      else: {:error, :blocked_without_reason}
  end

  defp validate_encoded_size(evidence) do
    case Jason.encode(evidence) do
      {:ok, encoded} when byte_size(encoded) <= @metadata_max_bytes -> :ok
      {:ok, _encoded} -> {:error, :evidence_too_large}
      {:error, _reason} -> {:error, :evidence_not_json_encodable}
    end
  end
end
