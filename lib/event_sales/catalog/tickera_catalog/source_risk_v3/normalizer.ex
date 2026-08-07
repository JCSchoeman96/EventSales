defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.Normalizer do
  @moduledoc """
  Sole native canonical fact-construction boundary for `source_risk.v3`.

  Validates registry membership, authority, semantic scope, and target shape.
  Constructs `CanonicalFact` values and classifies duplicate/conflict candidates.
  Does not set finding severity, Planner decisions, or persistence side effects.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Evidence

  @type normalize_ok :: %{
          fact: CanonicalFact.t(),
          duplicate_of: CanonicalFact.t() | nil,
          conflicts_with: [CanonicalFact.t()]
        }

  @spec normalize_evidence(Evidence.t(), keyword()) ::
          {:ok, CanonicalFact.t()} | {:error, atom() | {atom(), term()}}
  def normalize_evidence(evidence, opts \\ [])

  def normalize_evidence(%Evidence{} = evidence, opts) when is_list(opts) do
    run_id = Keyword.get(opts, :run_id)
    origin = Keyword.get(opts, :origin, "native")

    with :ok <- require_run_id(run_id),
         {:ok, origin} <- ContractRegistry.fetch_origin(origin),
         {:ok, dimension} <- ContractRegistry.fetch_dimension(evidence.dimension),
         {:ok, scope} <- ContractRegistry.fetch_scope(evidence.producer_scope),
         :ok <- validate_scope_for_dimension(dimension, scope),
         {:ok, state} <- ContractRegistry.fetch_state(evidence.state),
         :ok <- validate_state_for_dimension(dimension, state),
         {:ok, completeness} <- ContractRegistry.fetch_completeness(evidence.completeness),
         {:ok, authority_slot} <- ContractRegistry.authority_slot_for_dimension(dimension),
         {:ok, authority} <- ContractRegistry.authority_for_slot(authority_slot),
         :ok <- validate_state_for_authority(authority, state),
         :ok <- validate_producer_source_key(authority, evidence.producer_source_key),
         {:ok, target} <- CanonicalFact.validate_target_for_scope(scope, evidence.target),
         :ok <- reject_parent_as_variation(scope, target),
         {:ok, value} <- normalize_value(dimension, state, evidence.value) do
      fact = %CanonicalFact{
        run_id: run_id,
        dimension: dimension,
        semantic_scope: scope,
        target: target,
        authority_slot: authority_slot,
        authority: authority,
        state: state,
        value: value,
        completeness: completeness,
        origin: origin,
        provenance:
          Map.put(evidence.provenance, "producer_source_key", evidence.producer_source_key)
      }

      {:ok, fact}
    end
  end

  def normalize_evidence(_, _), do: {:error, :invalid_evidence}

  @spec classify_against_existing(CanonicalFact.t(), [CanonicalFact.t()]) :: normalize_ok()
  def classify_against_existing(%CanonicalFact{} = fact, existing) when is_list(existing) do
    {duplicates, conflicts} =
      Enum.reduce(existing, {nil, []}, fn other, {dup, conflicts} ->
        case CanonicalFact.compare_pair(fact, other) do
          :duplicate -> {dup || other, conflicts}
          :conflict -> {dup, [other | conflicts]}
          :different_identity -> {dup, conflicts}
        end
      end)

    %{
      fact: fact,
      duplicate_of: duplicates,
      conflicts_with: Enum.reverse(conflicts)
    }
  end

  @spec never_safe_state?(String.t()) :: boolean()
  def never_safe_state?(state)
      when state in [
             "unknown",
             "missing",
             "unsupported",
             "invalid",
             "producer_error",
             "parser_error"
           ] do
    true
  end

  def never_safe_state?(_), do: false

  defp require_run_id(run_id) when is_binary(run_id) and run_id != "", do: :ok
  defp require_run_id(_), do: {:error, :missing_run_id}

  defp validate_scope_for_dimension(dimension, scope) do
    if ContractRegistry.scope_allowed_for_dimension?(dimension, scope) do
      :ok
    else
      {:error, :scope_mismatch}
    end
  end

  defp validate_state_for_dimension(dimension, state) do
    if ContractRegistry.state_allowed_for_dimension?(dimension, state) do
      :ok
    else
      {:error, :state_not_allowed_for_dimension}
    end
  end

  defp validate_state_for_authority(authority, state) do
    if ContractRegistry.state_allowed_for_authority?(authority, state) do
      :ok
    else
      {:error, :authority_mismatch}
    end
  end

  defp validate_producer_source_key(authority, producer_source_key) do
    case ContractRegistry.producer_source_key_for_authority(authority) do
      {:ok, expected} ->
        # Accept exact expected key, or for event_name_meta the documented compound key prefix.
        if producer_source_key == expected or
             (authority == "auth.event_name_meta" and
                String.starts_with?(producer_source_key, "postmeta:_event_name")) do
          :ok
        else
          {:error, :authority_mismatch}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_parent_as_variation("parent_product", target) do
    if Map.has_key?(target, :woo_variation_id) do
      {:error, :parent_product_must_not_carry_variation_identity}
    else
      :ok
    end
  end

  defp reject_parent_as_variation(_scope, _target), do: :ok

  defp normalize_value("lifecycle", "present", value) when is_binary(value) do
    case ContractRegistry.allowed_values_for_dimension("lifecycle") do
      {:ok, allowed} ->
        if MapSet.member?(allowed, value) do
          {:ok, value}
        else
          {:error, :unknown_value}
        end

      other ->
        other
    end
  end

  defp normalize_value("product_type", "present", value) when is_binary(value) do
    case ContractRegistry.allowed_values_for_dimension("product_type") do
      {:ok, allowed} ->
        if MapSet.member?(allowed, value) do
          {:ok, value}
        else
          {:error, :undeclared_product_type}
        end

      other ->
        other
    end
  end

  defp normalize_value("event_link", "present", value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp normalize_value("event_link", "present", _), do: {:error, :invalid_event_link_value}

  defp normalize_value("ticket_template", "present", value)
       when is_binary(value) and value != "" do
    case ContractRegistry.validate_bounded_string(
           value,
           ContractRegistry.max_evidence_value_bytes()
         ) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_value("ticket_template", "present", _),
    do: {:error, :invalid_ticket_template_value}

  defp normalize_value(dimension, "present", value)
       when dimension in ["payment_plan", "membership", "bundle", "add_on"] do
    _ = value
    {:error, :unauthorized_semantic_claim}
  end

  defp normalize_value(dimension, "absent", value)
       when dimension in ["payment_plan", "membership", "bundle", "add_on"] do
    _ = value
    {:error, :unauthorized_semantic_claim}
  end

  defp normalize_value(_dimension, _state, nil), do: {:ok, nil}

  defp normalize_value(_dimension, state, value)
       when state != "present" and not is_nil(value) do
    # Non-present states may carry optional digests; keep bounded strings only.
    cond do
      is_binary(value) ->
        case ContractRegistry.validate_bounded_string(
               value,
               ContractRegistry.max_evidence_value_bytes()
             ) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      is_integer(value) and value > 0 ->
        {:ok, value}

      true ->
        {:error, :invalid_value}
    end
  end

  defp normalize_value(_dimension, _state, value), do: {:ok, value}
end
