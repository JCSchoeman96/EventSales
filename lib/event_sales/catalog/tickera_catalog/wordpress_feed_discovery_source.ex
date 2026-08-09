defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedDiscoverySource do
  @moduledoc """
  DiscoverySource adapter for the VS-26C WordPress Tickera catalog feed.

  Exact schema dispatch after fetch:
  - legacy v2/v1 → `legacy_v2_operational` (never routes through V2Adapter)
  - native v3 → SourceSystem binding, DiscoveryIntegrity-backed facts/findings
  """

  @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem

  alias EventSales.Catalog.TickeraCatalog.{
    DiscoveryResult,
    WordPressFeedClient,
    WordPressFeedResponse
  }

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.DiscoveryIntegrity
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.FindingPolicy
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Normalizer

  @native_schema_version "2026-08-07.v3"

  @impl true
  def discover(source_system_id, scope) when is_binary(source_system_id) and is_map(scope) do
    with {:ok, query} <- normalize_scope(scope),
         {:ok, response} <- WordPressFeedClient.fetch(query) do
      build_discovery_result(source_system_id, response)
    end
  end

  def discover(_source_system_id, _scope), do: {:error, :invalid_scope}

  defp build_discovery_result(configured_source_system_id, %WordPressFeedResponse{} = response) do
    case response.schema_version do
      @native_schema_version ->
        build_native_result(configured_source_system_id, response)

      _legacy ->
        {:ok, build_legacy_result(response)}
    end
  end

  defp build_legacy_result(response) do
    %DiscoveryResult{
      schema_version: response.schema_version,
      auto_apply_proof_complete?: response.auto_apply_proof_complete?,
      events: response.events,
      catalog_rows: response.catalog_rows,
      source_snapshot_at: response.source_snapshot_at,
      canonical_contract_version: nil,
      producer_version: nil,
      source_system_id: nil,
      discovery_snapshot_id: nil,
      normalization_mode: :legacy_v2_operational,
      evidence_origin: nil,
      canonical_source_risk_facts: [],
      canonical_source_risk_findings: []
    }
  end

  defp build_native_result(configured_source_system_id, response) do
    with {:ok, source_system} <- load_source_system(configured_source_system_id),
         :ok <-
           DiscoveryIntegrity.verify_source_system_id(
             source_system.base_url,
             response.source_system_id
           ),
         {:ok, facts, findings} <- normalize_native_evidence(response) do
      {:ok,
       %DiscoveryResult{
         schema_version: response.schema_version,
         auto_apply_proof_complete?: false,
         events: response.events,
         catalog_rows: response.catalog_rows,
         source_snapshot_at: response.source_snapshot_at,
         canonical_contract_version: response.canonical_contract_version,
         producer_version: response.producer_version,
         source_system_id: response.source_system_id,
         discovery_snapshot_id: response.discovery_snapshot_id,
         normalization_mode: :native_v3_review,
         evidence_origin: :native,
         canonical_source_risk_facts: facts,
         canonical_source_risk_findings: findings
       }}
    else
      {:error, :source_system_id_mismatch} -> {:error, :invalid_feed_response}
      {:error, :invalid_base_url} -> {:error, :invalid_feed_response}
      {:error, :missing_source_system} -> {:error, :invalid_feed_response}
      {:error, :invalid_source_system_base_url} -> {:error, :invalid_feed_response}
      {:error, _reason} -> {:error, :invalid_feed_response}
    end
  end

  defp load_source_system(configured_source_system_id) do
    case Ash.get(SourceSystem, configured_source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{base_url: base_url} = source}
      when is_binary(base_url) and base_url != "" ->
        {:ok, source}

      {:ok, %SourceSystem{}} ->
        {:error, :invalid_source_system_base_url}

      {:ok, nil} ->
        {:error, :missing_source_system}

      {:error, _} ->
        {:error, :missing_source_system}
    end
  end

  defp normalize_native_evidence(response) do
    run_id = response.discovery_snapshot_id
    # Successful native aggregation already proved a complete stable sequence.
    exhaustive_proven? = true

    Enum.reduce_while(response.evidence, {:ok, [], []}, fn evidence, {:ok, facts, findings} ->
      case Normalizer.normalize_evidence(evidence,
             run_id: run_id,
             origin: "native",
             exhaustive_proven?: exhaustive_proven?
           ) do
        {:ok, fact} ->
          absorb_normalized_fact(facts, findings, fact)

        {:error, _reason} ->
          {:halt, {:error, :invalid_feed_response}}
      end
    end)
    |> case do
      {:ok, facts, findings} ->
        {:ok, CanonicalFact.sort_facts(Enum.reverse(facts)), Enum.reverse(findings)}

      other ->
        other
    end
  end

  defp absorb_normalized_fact(facts, findings, fact) do
    classification = Normalizer.classify_against_existing(fact, facts)

    if classification.duplicate_of do
      merge_duplicate_fact(facts, findings, classification.duplicate_of, fact)
    else
      findings =
        findings
        |> prepend_actual_finding(FindingPolicy.evaluate(fact))
        |> prepend_conflict_findings(fact, classification.conflicts_with)

      {:cont, {:ok, [fact | facts], findings}}
    end
  end

  defp merge_duplicate_fact(facts, findings, duplicate_of, fact) do
    case Normalizer.merge_duplicate(duplicate_of, fact) do
      {:ok, merged} ->
        {:cont, {:ok, replace_fact(facts, duplicate_of, merged), findings}}

      {:error, _reason} ->
        {:halt, {:error, :invalid_feed_response}}
    end
  end

  defp replace_fact(facts, duplicate_of, merged) do
    Enum.map(facts, fn existing ->
      if existing == duplicate_of, do: merged, else: existing
    end)
  end

  defp prepend_conflict_findings(findings, fact, conflicts) do
    Enum.reduce(conflicts, findings, fn other, acc ->
      prepend_actual_finding(acc, FindingPolicy.evaluate_conflict(fact, other))
    end)
  end

  defp prepend_actual_finding(findings, result) do
    if actual_finding?(result) do
      [result | findings]
    else
      findings
    end
  end

  defp actual_finding?(result) when is_map(result) do
    is_binary(result[:qualified_finding_id]) and result[:qualified_finding_id] != "" and
      result[:severity] in [:info, :warning, :blocking]
  end

  defp normalize_scope(scope) do
    scope = string_key_map(scope)

    with true <- scope["kind"] == "wordpress_feed",
         {:ok, modes} <- selected_modes(scope),
         {:one_mode, [mode]} <- {:one_mode, modes},
         {:ok, query} <- query_for_mode(mode, scope) do
      {:ok, query}
    else
      _error -> {:error, :invalid_scope}
    end
  end

  defp selected_modes(scope) do
    modes =
      []
      |> maybe_add(scope["mode"] == "full", :full)
      |> maybe_add(present?(scope["product_id"]), :product_id)
      |> maybe_add(present?(scope["variation_id"]), :variation_id)
      |> maybe_add(present?(scope["event_id"]), :event_id)
      |> maybe_add(present?(scope["updated_since"]), :updated_since)

    {:ok, modes}
  end

  defp query_for_mode(:full, _scope), do: {:ok, %{"mode" => "full"}}

  defp query_for_mode(:product_id, scope) do
    with {:ok, id} <- positive_id(scope["product_id"]) do
      {:ok, %{"product_id" => id}}
    end
  end

  defp query_for_mode(:variation_id, scope) do
    with {:ok, id} <- positive_id(scope["variation_id"]) do
      {:ok, %{"variation_id" => id}}
    end
  end

  defp query_for_mode(:event_id, scope) do
    with {:ok, id} <- positive_id(scope["event_id"]) do
      {:ok, %{"event_id" => id}}
    end
  end

  defp query_for_mode(:updated_since, scope) do
    value = scope["updated_since"]

    with true <- is_binary(value),
         true <-
           Regex.match?(
             ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/,
             value
           ),
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, %{"updated_since" => value}}
    else
      _error -> {:error, :invalid}
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid}
    end
  end

  defp positive_id(_value), do: {:error, :invalid}

  defp string_key_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp present?(value), do: value not in [nil, ""]
  defp maybe_add(modes, true, mode), do: modes ++ [mode]
  defp maybe_add(modes, false, _mode), do: modes
end
