defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.Evidence do
  @moduledoc """
  Transport-level native `source_risk.v3` evidence representation and validation.

  Validates shape, closed wire enums, bounds, and provenance allowlists only.
  Does not decide severity, disposition, AutoApply eligibility, or Planner action.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry

  @enforce_keys [
    :dimension,
    :producer_scope,
    :target,
    :state,
    :producer_source_key,
    :completeness,
    :provenance
  ]

  defstruct [
    :dimension,
    :producer_scope,
    :target,
    :state,
    :producer_source_key,
    :completeness,
    :provenance,
    :value,
    related_targets: %{}
  ]

  @type t :: %__MODULE__{
          dimension: String.t(),
          producer_scope: String.t(),
          target: %{required(atom()) => pos_integer()},
          state: String.t(),
          producer_source_key: String.t(),
          completeness: String.t(),
          provenance: map(),
          value: String.t() | pos_integer() | nil,
          related_targets: map()
        }

  @spec validate(map()) :: {:ok, t()} | {:error, atom() | {atom(), term()}}
  def validate(input) when is_map(input) do
    with :ok <- reject_non_string_map_keys(input),
         {:ok, dimension} <-
           require_closed_string(input, "dimension", &ContractRegistry.fetch_dimension/1),
         {:ok, producer_scope} <-
           require_closed_string(input, "producer_scope", &ContractRegistry.fetch_scope/1),
         {:ok, state} <- require_closed_string(input, "state", &fetch_producer_state/1),
         {:ok, completeness} <-
           require_closed_string(input, "completeness", &ContractRegistry.fetch_completeness/1),
         {:ok, producer_source_key} <- require_bounded_key(input, "producer_source_key"),
         {:ok, target} <- validate_target(Map.get(input, "target"), producer_scope),
         {:ok, value} <- validate_value(Map.get(input, "value"), state, dimension),
         {:ok, related_targets} <- validate_related_targets(Map.get(input, "related_targets")),
         {:ok, provenance} <- validate_provenance(Map.get(input, "provenance")) do
      {:ok,
       %__MODULE__{
         dimension: dimension,
         producer_scope: producer_scope,
         target: target,
         state: state,
         producer_source_key: producer_source_key,
         completeness: completeness,
         provenance: provenance,
         value: value,
         related_targets: related_targets
       }}
    end
  end

  def validate(_), do: {:error, :invalid_evidence_envelope}

  defp fetch_producer_state(state) do
    if ContractRegistry.producer_emittable_state?(state) do
      {:ok, state}
    else
      {:error, :unknown_state}
    end
  end

  defp reject_non_string_map_keys(map) do
    if Enum.all?(Map.keys(map), &is_binary/1) do
      :ok
    else
      {:error, :non_string_map_keys}
    end
  end

  defp require_closed_string(input, key, fetch_fun) do
    case Map.fetch(input, key) do
      :error ->
        {:error, {:missing_field, key}}

      {:ok, value} when is_binary(value) ->
        case ContractRegistry.validate_closed_id(value) do
          :ok ->
            case fetch_fun.(value) do
              {:ok, fetched} -> {:ok, fetched}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _} ->
        {:error, {:invalid_field_type, key}}
    end
  end

  defp require_bounded_key(input, key) do
    case Map.fetch(input, key) do
      :error ->
        {:error, {:missing_field, key}}

      {:ok, value} when is_binary(value) ->
        case ContractRegistry.validate_bounded_string(
               value,
               ContractRegistry.max_producer_source_key_bytes()
             ) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        {:error, {:invalid_field_type, key}}
    end
  end

  defp validate_target(target, scope) when is_map(target) do
    with :ok <- reject_non_string_map_keys(target),
         {:ok, required_keys} <- ContractRegistry.target_keys_for_scope(scope),
         :ok <- ensure_exact_target_keys(target, required_keys),
         {:ok, normalized} <- normalize_target_ids(target, required_keys) do
      {:ok, normalized}
    else
      {:error, :unknown_scope} -> {:error, :unknown_scope}
      other -> other
    end
  end

  defp validate_target(nil, _scope), do: {:error, {:missing_field, "target"}}
  defp validate_target(_, _scope), do: {:error, :invalid_target}

  defp ensure_exact_target_keys(target, required_keys) do
    expected = MapSet.new(Enum.map(required_keys, &Atom.to_string/1))
    actual = MapSet.new(Map.keys(target))

    cond do
      MapSet.equal?(expected, actual) -> :ok
      true -> {:error, :invalid_target_shape}
    end
  end

  defp normalize_target_ids(target, required_keys) do
    Enum.reduce_while(required_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      string_key = Atom.to_string(key)

      case Map.fetch(target, string_key) do
        {:ok, id} when is_integer(id) and id > 0 ->
          {:cont, {:ok, Map.put(acc, key, id)}}

        {:ok, _} ->
          {:halt, {:error, :invalid_target_id}}

        :error ->
          {:halt, {:error, :invalid_target_shape}}
      end
    end)
  end

  defp validate_value(nil, "present", dimension)
       when dimension in ["lifecycle", "product_type", "event_link", "ticket_template"] do
    {:error, :missing_value_for_present}
  end

  defp validate_value(nil, _state, _dimension), do: {:ok, nil}

  defp validate_value(value, _state, "event_link") when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp validate_value(value, _state, _dimension) when is_binary(value) do
    case ContractRegistry.validate_bounded_string(
           value,
           ContractRegistry.max_evidence_value_bytes()
         ) do
      :ok ->
        if value == "" do
          {:error, :empty_value}
        else
          {:ok, value}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_value(_value, _state, _dimension), do: {:error, :invalid_value}

  defp validate_related_targets(nil), do: {:ok, %{}}

  defp validate_related_targets(related) when is_map(related) do
    with :ok <- reject_non_string_map_keys(related),
         :ok <- ensure_related_target_allowlist(related) do
      Enum.reduce_while(related, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        atom_key =
          case key do
            "tickera_event_id" -> :tickera_event_id
            "woo_product_id" -> :woo_product_id
            "woo_variation_id" -> :woo_variation_id
            "ticket_template_id" -> :ticket_template_id
          end

        if is_integer(value) and value > 0 do
          {:cont, {:ok, Map.put(acc, atom_key, value)}}
        else
          {:halt, {:error, :invalid_related_target}}
        end
      end)
    end
  end

  defp validate_related_targets(_), do: {:error, :invalid_related_targets}

  defp ensure_related_target_allowlist(related) do
    allowed = MapSet.new(~w(tickera_event_id woo_product_id woo_variation_id ticket_template_id))

    if MapSet.subset?(MapSet.new(Map.keys(related)), allowed) do
      :ok
    else
      {:error, :unknown_related_target_key}
    end
  end

  defp validate_provenance(nil), do: {:error, {:missing_field, "provenance"}}

  defp validate_provenance(provenance) when is_map(provenance) do
    with :ok <- reject_non_string_map_keys(provenance),
         :ok <- reject_forbidden_provenance_keys(provenance),
         :ok <- ensure_provenance_allowlist(provenance),
         {:ok, normalized} <- normalize_provenance(provenance) do
      {:ok, normalized}
    end
  end

  defp validate_provenance(_), do: {:error, :invalid_provenance}

  defp reject_forbidden_provenance_keys(provenance) do
    rejected = ContractRegistry.rejected_producer_provenance_keys()

    if Enum.any?(Map.keys(provenance), &MapSet.member?(rejected, &1)) do
      {:error, :forbidden_provenance_key}
    else
      :ok
    end
  end

  defp ensure_provenance_allowlist(provenance) do
    allowed = ContractRegistry.producer_provenance_keys()

    if MapSet.subset?(MapSet.new(Map.keys(provenance)), allowed) do
      :ok
    else
      {:error, :unknown_provenance_key}
    end
  end

  defp normalize_provenance(provenance) do
    Enum.reduce_while(provenance, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_provenance_value(key, value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_provenance_value(key, value)
       when key in ["woo_product_id", "woo_variation_id", "tickera_event_id"] do
    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, :invalid_provenance_id}
    end
  end

  defp normalize_provenance_value("raw_producer_code", value) when is_binary(value) do
    case ContractRegistry.validate_bounded_string(
           value,
           ContractRegistry.max_raw_producer_code_bytes()
         ) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_provenance_value("producer_source_key", value) when is_binary(value) do
    case ContractRegistry.validate_bounded_string(
           value,
           ContractRegistry.max_producer_source_key_bytes()
         ) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_provenance_value(key, value)
       when key in ["discovery_snapshot_id", "producer_version"] and is_binary(value) do
    case ContractRegistry.validate_bounded_string(value, 128) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_provenance_value(_key, _value), do: {:error, :invalid_provenance_value}
end
