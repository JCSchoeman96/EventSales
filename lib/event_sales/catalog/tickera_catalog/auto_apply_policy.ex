defmodule EventSales.Catalog.TickeraCatalog.AutoApplyPolicy do
  @moduledoc """
  Pure, deterministic and fail-closed eligibility policy for conservative catalog auto-Apply.
  """

  @policy_version "conservative_auto_apply.v1"
  @snapshot_version "tickera_catalog_plan.v2"
  @zero_history_fields ~w(
    affected_pending_lines affected_quantity eligible_lines eligible_quantity
    deferred_lines deferred_quantity conflicting_lines conflicting_quantity
    already_mapped_lines already_mapped_quantity
  )

  @spec evaluate(map()) :: {:ok, map()} | {:error, map()}
  def evaluate(input) when is_map(input) do
    snapshot = Map.get(input, :snapshot, %{})

    reasons =
      []
      |> require_input(input)
      |> require_version(input, snapshot)
      |> require_origin(input)
      |> require_actions(snapshot)
      |> require_no_findings(input, snapshot)
      |> require_complete_safe_risks(snapshot)
      |> require_no_variations(snapshot)
      |> require_zero_history(snapshot)
      |> Enum.uniq()
      |> Enum.sort()

    result = if reasons == [], do: :eligible, else: :ineligible

    {:ok,
     %{
       result: result,
       reason_codes: reasons,
       summaries: summaries(snapshot)
     }}
  rescue
    _error ->
      {:error, %{result: :error, reason_codes: [:policy_error], summaries: empty_summaries()}}
  end

  def evaluate(_input),
    do:
      {:ok,
       %{result: :ineligible, reason_codes: [:missing_policy_input], summaries: empty_summaries()}}

  defp require_input(reasons, input) do
    required = [:run_id, :dry_run_hash, :origin, :snapshot, :findings, :policy_version]

    if Enum.all?(required, &Map.has_key?(input, &1)),
      do: reasons,
      else: [:missing_policy_input | reasons]
  end

  defp require_version(reasons, input, snapshot) do
    reasons
    |> maybe_add(input[:policy_version] != @policy_version, :unsupported_policy_version)
    |> maybe_add(
      snapshot["snapshot_schema_version"] != @snapshot_version,
      :unsupported_snapshot_version
    )
  end

  defp require_origin(reasons, input),
    do:
      maybe_add(
        reasons,
        input[:origin] not in [:targeted_catalog_change, "targeted_catalog_change"],
        :unsupported_origin
      )

  defp require_actions(reasons, snapshot) do
    allowed = [
      {"event_actions", ~w(create reuse)},
      {"ticket_type_actions", ~w(create reuse)},
      {"product_mapping_actions", ~w(create)}
    ]

    if Enum.all?(allowed, fn {key, actions} ->
         is_list(snapshot[key]) and
           Enum.all?(snapshot[key], &(is_map(&1) and &1["action"] in actions))
       end) do
      reasons
    else
      [:unsupported_action | reasons]
    end
  end

  defp require_no_findings(reasons, input, snapshot) do
    if input[:findings] == [] and snapshot["findings"] == [],
      do: reasons,
      else: [:finding_present | reasons]
  end

  defp require_complete_safe_risks(reasons, snapshot) do
    facts = snapshot["source_risks"]
    expected = expected_risk_keys(snapshot)

    cond do
      not is_list(facts) ->
        [:missing_source_risk_proof | reasons]

      duplicate_risk_keys?(facts) ->
        [:duplicate_source_risk_proof | reasons]

      MapSet.new(Enum.map(facts, &risk_key/1)) != expected ->
        [:missing_source_risk_proof | reasons]

      Enum.any?(facts, &(&1["evidence_classification"] != "explicit_safe")) ->
        [:source_risk_present | reasons]

      true ->
        reasons
    end
  end

  defp expected_risk_keys(snapshot) do
    event_keys =
      snapshot["event_actions"]
      |> List.wrap()
      |> Enum.map(& &1["external_event_id"])
      |> Enum.filter(&is_integer/1)
      |> Enum.map(&{"event", &1, "private_event"})

    product_ids =
      snapshot["product_mapping_actions"]
      |> List.wrap()
      |> Enum.map(& &1["woo_product_id"])
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    product_codes =
      ~w(private_product subscription payment_plan membership bundle add_on missing_ticket_template unsupported_product_type)

    product_keys = for id <- product_ids, code <- product_codes, do: {"product", id, code}

    variation_keys =
      snapshot["product_mapping_actions"]
      |> List.wrap()
      |> Enum.map(& &1["woo_variation_id"])
      |> Enum.filter(&is_integer/1)
      |> Enum.flat_map(fn id ->
        [
          {"variation", id, "private_variation"},
          {"variation", id, "variation_mapping_required"}
        ]
      end)

    MapSet.new(event_keys ++ product_keys ++ variation_keys)
  end

  defp risk_key(fact), do: {fact["target_type"], fact["target_id"], fact["code"]}

  defp duplicate_risk_keys?(facts) do
    keys = Enum.map(facts, &risk_key/1)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp require_no_variations(reasons, snapshot) do
    variation? =
      Enum.any?(snapshot["ticket_type_actions"] || [], &present?(&1["external_variation_id"])) or
        Enum.any?(
          snapshot["product_mapping_actions"] || [],
          &present?(&1["woo_variation_id"])
        )

    maybe_add(reasons, variation?, :variation_present)
  end

  defp require_zero_history(reasons, snapshot) do
    historical = snapshot["historical_impact"]
    totals = is_map(historical) && historical["totals"]

    zero? =
      is_map(totals) and
        Enum.all?(@zero_history_fields, &(Map.get(totals, &1) == 0)) and
        historical["warning_count"] == 0 and
        historical["unresolved_destination_count"] == 0 and
        historical["unknown_classification_count"] == 0

    maybe_add(reasons, not zero?, :historical_impact_present)
  end

  defp summaries(snapshot) do
    actions =
      (snapshot["event_actions"] || []) ++
        (snapshot["ticket_type_actions"] || []) ++
        (snapshot["product_mapping_actions"] || [])

    action_summary = %{
      "event_create" => count_action(snapshot["event_actions"], "create"),
      "event_reuse" => count_action(snapshot["event_actions"], "reuse"),
      "ticket_type_create" => count_action(snapshot["ticket_type_actions"], "create"),
      "ticket_type_reuse" => count_action(snapshot["ticket_type_actions"], "reuse"),
      "product_mapping_create" => count_action(snapshot["product_mapping_actions"], "create"),
      "total" => length(actions)
    }

    %{
      action_summary: action_summary,
      finding_summary: %{
        "total" => length(snapshot["findings"] || []),
        "info" => 0,
        "warning" => 0,
        "blocking" => 0,
        "unknown" => 0
      },
      historical_summary: history_summary(snapshot["historical_impact"])
    }
  end

  defp empty_summaries,
    do: %{action_summary: %{}, finding_summary: %{}, historical_summary: %{}}

  defp history_summary(%{"totals" => totals} = historical) do
    total_keys =
      ~w(affected_pending_lines affected_quantity eligible_lines deferred_lines conflicting_lines already_mapped_lines)

    historical_keys =
      ~w(warning_count unresolved_destination_count unknown_classification_count)

    Map.merge(summary_values(totals, total_keys), summary_values(historical, historical_keys))
  end

  defp history_summary(_historical), do: %{}

  defp count_action(values, action) when is_list(values),
    do: Enum.count(values, &(&1["action"] == action))

  defp count_action(_values, _action), do: 0
  defp summary_values(values, keys), do: Map.new(keys, &{&1, values[&1] || 0})
  defp present?(value), do: value not in [nil, ""]
  defp maybe_add(reasons, true, reason), do: [reason | reasons]
  defp maybe_add(reasons, false, _reason), do: reasons
end
