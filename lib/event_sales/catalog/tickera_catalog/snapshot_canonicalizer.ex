defmodule EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer do
  @moduledoc """
  Closed deterministic byte and hash boundary for `tickera_catalog_plan.v2`.
  """

  @top_level_keys ~w(
    snapshot_schema_version source_system_id origin event_actions
    ticket_type_actions product_mapping_actions findings source_risks
    historical_impact identity_membership_proof touched_identifiers
  )
  @historical_keys ~w(
    totals warning_count unresolved_destination_count unknown_classification_count destinations
  )
  @total_keys ~w(
    affected_pending_lines affected_quantity eligible_lines eligible_quantity
    deferred_lines deferred_quantity conflicting_lines conflicting_quantity
    already_mapped_lines already_mapped_quantity
  )
  @proof_keys ~w(events ticket_types product_mappings)
  @touched_keys ~w(event_ids ticket_type_ids mapping_ids product_keys)
  @origins ~w(human_admin targeted_catalog_change legacy_unknown)

  @spec canonicalize(map()) ::
          {:ok, binary(), String.t()}
          | {:error, :invalid_snapshot_schema | :invalid_snapshot_value}
  def canonicalize(snapshot) when is_map(snapshot) do
    with false <- contains_float?(snapshot),
         :ok <- validate_schema(snapshot),
         {:ok, normalized} <- normalize(snapshot),
         {:ok, bytes} <- encode(normalized) do
      hash = bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      {:ok, bytes, hash}
    else
      true -> {:error, :invalid_snapshot_value}
      error -> error
    end
  end

  def canonicalize(_snapshot), do: {:error, :invalid_snapshot_schema}

  defp validate_schema(snapshot) do
    historical = snapshot["historical_impact"]
    proof = snapshot["identity_membership_proof"]
    touched = snapshot["touched_identifiers"]

    if exact_keys?(snapshot, @top_level_keys) and
         snapshot["snapshot_schema_version"] == "tickera_catalog_plan.v2" and
         uuid?(snapshot["source_system_id"]) and snapshot["origin"] in @origins and
         lists?(
           snapshot,
           ~w(event_actions ticket_type_actions product_mapping_actions findings source_risks)
         ) and
         exact_keys?(historical, @historical_keys) and
         exact_non_negative_integers?(historical["totals"], @total_keys) and
         non_negative_integer?(historical["warning_count"]) and
         non_negative_integer?(historical["unresolved_destination_count"]) and
         non_negative_integer?(historical["unknown_classification_count"]) and
         is_list(historical["destinations"]) and
         exact_list_container?(proof, @proof_keys) and
         exact_list_container?(touched, @touched_keys) do
      :ok
    else
      {:error, :invalid_snapshot_schema}
    end
  end

  defp normalize(%Decimal{} = value) do
    normalized =
      if Decimal.equal?(value, Decimal.new(0)) do
        "0"
      else
        value |> Decimal.normalize() |> Decimal.to_string(:normal)
      end

    {:ok, normalized}
  end

  defp normalize(%DateTime{} = value) do
    utc = DateTime.shift_zone!(value, "Etc/UTC")
    fixed_precision = %{utc | microsecond: {elem(utc.microsecond, 0), 6}}
    {:ok, DateTime.to_iso8601(fixed_precision, :extended)}
  end

  defp normalize(value) when is_float(value), do: {:error, :invalid_snapshot_value}

  defp normalize(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize(values) when is_list(values) do
    with {:ok, normalized} <- map_ok(values, &normalize/1) do
      {:ok, Enum.sort_by(normalized, &sort_bytes/1)}
    end
  end

  defp normalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize(value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize(_value), do: {:error, :invalid_snapshot_value}

  defp encode(value) do
    try do
      {:ok, IO.iodata_to_binary(encode_iodata(value))}
    rescue
      Protocol.UndefinedError -> {:error, :invalid_snapshot_value}
    end
  end

  defp encode_iodata(%{} = map) do
    entries =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ?:, encode_iodata(value)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  defp encode_iodata(values) when is_list(values),
    do: [?[, Enum.intersperse(Enum.map(values, &encode_iodata/1), ?,), ?]]

  defp encode_iodata(value), do: Jason.encode!(value)

  defp sort_bytes(value), do: value |> encode_iodata() |> IO.iodata_to_binary()

  defp exact_keys?(map, keys) when is_map(map),
    do: map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_map, _keys), do: false

  defp exact_list_container?(map, keys),
    do: exact_keys?(map, keys) and lists?(map, keys)

  defp exact_non_negative_integers?(map, keys) do
    exact_keys?(map, keys) and Enum.all?(keys, &non_negative_integer?(map[&1]))
  end

  defp lists?(map, keys) when is_map(map), do: Enum.all?(keys, &is_list(map[&1]))
  defp lists?(_map, _keys), do: false
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value)) and value == String.downcase(value)
  end

  defp uuid?(_value), do: false

  defp map_ok(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp contains_float?(value) when is_float(value), do: true
  defp contains_float?(%Decimal{}), do: false
  defp contains_float?(%DateTime{}), do: false
  defp contains_float?(values) when is_list(values), do: Enum.any?(values, &contains_float?/1)

  defp contains_float?(%{} = map),
    do: Enum.any?(map, fn {_key, value} -> contains_float?(value) end)

  defp contains_float?(_value), do: false
end
