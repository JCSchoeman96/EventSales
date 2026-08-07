defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact do
  @moduledoc """
  Canonical `source_risk.v3` evidence fact with locked identity and semantic equality.

  Identity excludes state, value, legacy raw codes, finding codes, translation rule ids,
  and source emitters.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry

  @enforce_keys [
    :run_id,
    :dimension,
    :semantic_scope,
    :target,
    :authority_slot,
    :authority,
    :state,
    :completeness,
    :origin
  ]

  defstruct [
    :run_id,
    :dimension,
    :semantic_scope,
    :target,
    :authority_slot,
    :authority,
    :state,
    :completeness,
    :origin,
    :value,
    provenance: []
  ]

  @type target :: %{required(atom()) => pos_integer()}
  @type provenance_record :: map()

  @type t :: %__MODULE__{
          run_id: String.t(),
          dimension: String.t(),
          semantic_scope: String.t(),
          target: target(),
          authority_slot: String.t(),
          authority: String.t(),
          state: String.t(),
          completeness: String.t(),
          origin: String.t(),
          value: String.t() | pos_integer() | nil,
          provenance: [provenance_record()]
        }

  @type identity :: %{
          run_id: String.t(),
          dimension: String.t(),
          semantic_scope: String.t(),
          target: target(),
          authority_slot: String.t()
        }

  @type semantic_claim :: %{
          state: String.t(),
          value: String.t() | pos_integer() | nil,
          completeness: String.t(),
          semantic_scope: String.t(),
          authority_slot: String.t(),
          origin: String.t()
        }

  @spec identity(t()) :: identity()
  def identity(%__MODULE__{} = fact) do
    %{
      run_id: fact.run_id,
      dimension: fact.dimension,
      semantic_scope: fact.semantic_scope,
      target: canonicalize_target(fact.target),
      authority_slot: fact.authority_slot
    }
  end

  @spec same_identity?(t(), t()) :: boolean()
  def same_identity?(%__MODULE__{} = left, %__MODULE__{} = right) do
    identity(left) == identity(right)
  end

  @spec semantic_claim(t()) :: semantic_claim()
  def semantic_claim(%__MODULE__{} = fact) do
    %{
      state: fact.state,
      value: normalize_claim_value(fact.value),
      completeness: fact.completeness,
      semantic_scope: fact.semantic_scope,
      authority_slot: fact.authority_slot,
      origin: fact.origin
    }
  end

  @spec same_semantic_claim?(t(), t()) :: boolean()
  def same_semantic_claim?(%__MODULE__{} = left, %__MODULE__{} = right) do
    semantic_claim(left) == semantic_claim(right)
  end

  @spec compare_pair(t(), t()) :: :duplicate | :conflict | :different_identity
  def compare_pair(%__MODULE__{} = left, %__MODULE__{} = right) do
    cond do
      not same_identity?(left, right) -> :different_identity
      same_semantic_claim?(left, right) -> :duplicate
      true -> :conflict
    end
  end

  @spec compare_key(t()) :: tuple()
  def compare_key(%__MODULE__{} = fact) do
    {
      fact.dimension,
      fact.semantic_scope,
      target_canonical_json(fact.target),
      fact.authority_slot,
      fact.origin,
      fact.state,
      normalize_claim_value(fact.value),
      fact.completeness
    }
  end

  @spec sort_facts([t()]) :: [t()]
  def sort_facts(facts) when is_list(facts) do
    Enum.sort_by(facts, &compare_key/1)
  end

  @spec sort_provenance_records([provenance_record()]) :: [provenance_record()]
  def sort_provenance_records(records) when is_list(records) do
    Enum.sort_by(records, &provenance_sort_key/1)
  end

  @spec target_canonical_json(target()) :: String.t()
  def target_canonical_json(target) when is_map(target) do
    target
    |> canonicalize_target()
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> then(fn pairs ->
      "{" <>
        Enum.map_join(pairs, ",", fn {key, value} -> ~s("#{key}":#{value}) end) <>
        "}"
    end)
  end

  @spec canonicalize_target(target()) :: target()
  def canonicalize_target(target) when is_map(target) do
    target
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
    |> Map.new()
  end

  @spec validate_target_for_scope(String.t(), map()) ::
          {:ok, target()} | {:error, atom()}
  def validate_target_for_scope(scope, target) when is_map(target) do
    with {:ok, required_keys} <- ContractRegistry.target_keys_for_scope(scope),
         :ok <- ensure_exact_keys(target, required_keys),
         :ok <- ensure_positive_ids(target) do
      {:ok, canonicalize_target(target)}
    end
  end

  def validate_target_for_scope(_scope, _target), do: {:error, :invalid_target}

  defp ensure_exact_keys(target, required_keys) do
    expected = MapSet.new(required_keys)
    actual = MapSet.new(Map.keys(target))

    if MapSet.equal?(expected, actual) do
      :ok
    else
      {:error, :invalid_target_shape}
    end
  end

  defp ensure_positive_ids(target) do
    if Enum.all?(target, fn {_key, value} -> is_integer(value) and value > 0 end) do
      :ok
    else
      {:error, :invalid_target_id}
    end
  end

  defp normalize_claim_value(nil), do: nil
  defp normalize_claim_value(value) when is_integer(value), do: value
  defp normalize_claim_value(value) when is_binary(value), do: value

  defp provenance_sort_key(record) when is_map(record) do
    record
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end
