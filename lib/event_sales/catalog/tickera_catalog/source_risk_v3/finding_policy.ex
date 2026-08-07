defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.FindingPolicy do
  @moduledoc """
  Disposition and severity policy for native `source_risk.v3` canonical facts.

  Severity is policy-owned. State is not severity. Safe proofs are dimension-local only
  and never imply row/target/plan/run/Apply safety. Native safe-negative allowlist is empty.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry

  @type disposition_result :: %{
          disposition: String.t(),
          severity: :blocking | nil,
          qualified_finding_id: String.t() | nil,
          dimension_local_only?: boolean(),
          implies_row_safe?: false,
          implies_target_safe?: false,
          implies_plan_safe?: false,
          implies_run_safe?: false,
          implies_apply_eligible?: false
        }

  @spec evaluate(CanonicalFact.t()) :: disposition_result()
  def evaluate(%CanonicalFact{} = fact) do
    fact
    |> disposition_for_fact()
    |> finalize()
  end

  @spec evaluate_conflict(CanonicalFact.t(), CanonicalFact.t()) :: disposition_result()
  def evaluate_conflict(%CanonicalFact{} = left, %CanonicalFact{} = right) do
    case CanonicalFact.compare_pair(left, right) do
      :conflict ->
        finalize(%{
          disposition: "blocking_conflict",
          severity: :blocking,
          qualified_finding_id: "contract.evidence_conflict",
          dimension_local_only?: true
        })

      :duplicate ->
        finalize(%{
          disposition: "not_applicable",
          severity: nil,
          qualified_finding_id: nil,
          dimension_local_only?: true
        })

      :different_identity ->
        finalize(%{
          disposition: "blocking_contract_error",
          severity: :blocking,
          qualified_finding_id: "contract.contract_violation",
          dimension_local_only?: true
        })
    end
  end

  @spec evaluate_contract_error(atom()) :: disposition_result()
  def evaluate_contract_error(reason) when is_atom(reason) do
    {disposition, finding_id} =
      case reason do
        :scope_mismatch -> {"blocking_scope_mismatch", "contract.scope_mismatch"}
        :authority_mismatch -> {"blocking_authority_mismatch", "contract.authority_mismatch"}
        :unknown_dimension -> {"blocking_contract_error", "contract.contract_violation"}
        :unknown_scope -> {"blocking_contract_error", "contract.contract_violation"}
        :unknown_state -> {"blocking_contract_error", "contract.contract_violation"}
        :unknown_value -> {"blocking_contract_error", "contract.contract_violation"}
        :undeclared_product_type -> {"blocking_invalid", "contract.contract_violation"}
        :parser_error -> {"blocking_error", "contract.parser_error"}
        _ -> {"blocking_contract_error", "contract.contract_violation"}
      end

    finalize(%{
      disposition: disposition,
      severity: :blocking,
      qualified_finding_id: finding_id,
      dimension_local_only?: true
    })
  end

  @spec native_safe_negative_allowlist_empty?() :: true
  def native_safe_negative_allowlist_empty? do
    ContractRegistry.safe_negative_allowlist() == [] and
      ContractRegistry.member_of_safe_negative_allowlist?(%{}) == false
  end

  @spec implies_apply_safety?(disposition_result()) :: false
  def implies_apply_safety?(%{
        implies_row_safe?: false,
        implies_target_safe?: false,
        implies_plan_safe?: false,
        implies_run_safe?: false,
        implies_apply_eligible?: false
      }),
      do: false

  defp disposition_for_fact(%CanonicalFact{} = fact) do
    cond do
      safe_positive?(fact) ->
        %{
          disposition: "safe_positive_proof",
          severity: nil,
          qualified_finding_id: nil,
          dimension_local_only?: true
        }

      explicit_risk = explicit_risk(fact) ->
        explicit_risk

      blocking = blocking_for_state(fact) ->
        blocking

      true ->
        # Native v3 MVP safe-negative allowlist is empty; unmatched claims fail closed.
        _ = ContractRegistry.safe_negative_allowlist()

        %{
          disposition: "blocking_contract_error",
          severity: :blocking,
          qualified_finding_id: "contract.contract_violation",
          dimension_local_only?: true
        }
    end
  end

  defp safe_positive?(%CanonicalFact{} = fact) do
    Enum.any?(ContractRegistry.safe_positive_rules(), fn rule ->
      MapSet.member?(rule.scopes, fact.semantic_scope) and
        fact.dimension == rule.dimension and
        fact.state == rule.state and
        fact.authority == rule.authority and
        ContractRegistry.completeness?(fact.completeness) and
        value_matches_safe_positive?(rule.value, fact)
    end)
  end

  defp value_matches_safe_positive?(:any_valid_id, %CanonicalFact{value: value})
       when is_binary(value) and value != "",
       do: true

  defp value_matches_safe_positive?(:resolved_tickera_event_id, %CanonicalFact{value: value})
       when is_integer(value) and value > 0,
       do: true

  defp value_matches_safe_positive?(expected, %CanonicalFact{value: value})
       when is_binary(expected),
       do: value == expected

  defp value_matches_safe_positive?(_, _), do: false

  defp explicit_risk(%CanonicalFact{
         dimension: "lifecycle",
         state: "present",
         value: value
       })
       when value in ["private", "draft", "trash", "deleted"] do
    finding =
      case value do
        "private" -> "source_risk.lifecycle_private"
        "draft" -> "source_risk.lifecycle_draft"
        "trash" -> "source_risk.lifecycle_trashed"
        "deleted" -> "source_risk.lifecycle_deleted"
      end

    %{
      disposition: "explicit_risk",
      severity: :blocking,
      qualified_finding_id: finding,
      dimension_local_only?: true
    }
  end

  defp explicit_risk(%CanonicalFact{
         dimension: "ticket_template",
         state: "absent",
         completeness: "exhaustive"
       }) do
    %{
      disposition: "explicit_risk",
      severity: :blocking,
      qualified_finding_id: "source_risk.missing_ticket_template",
      dimension_local_only?: true
    }
  end

  defp explicit_risk(%CanonicalFact{
         dimension: "event_link",
         state: "absent",
         completeness: "exhaustive"
       }) do
    %{
      disposition: "explicit_risk",
      severity: :blocking,
      qualified_finding_id: "source_risk.missing_tickera_event",
      dimension_local_only?: true
    }
  end

  defp explicit_risk(%CanonicalFact{dimension: "subscription", state: "present"}) do
    %{
      disposition: "explicit_risk",
      severity: :blocking,
      qualified_finding_id: "source_risk.subscription",
      dimension_local_only?: true
    }
  end

  defp explicit_risk(_fact), do: nil

  defp blocking_for_state(%CanonicalFact{state: "unknown"} = fact) do
    %{
      disposition: "blocking_unknown",
      severity: :blocking,
      qualified_finding_id: unresolved_finding(fact),
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{state: "missing"}) do
    %{
      disposition: "blocking_missing",
      severity: :blocking,
      qualified_finding_id: "contract.blocking_missing",
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{state: "unsupported"} = fact) do
    finding =
      case fact.dimension do
        "payment_plan" -> "source_risk.payment_plan"
        "membership" -> "source_risk.membership"
        "bundle" -> "source_risk.bundle"
        "add_on" -> "source_risk.add_on"
        "product_type" -> "contract.blocking_unsupported"
        _ -> "contract.blocking_unsupported"
      end

    %{
      disposition: "blocking_unsupported",
      severity: :blocking,
      qualified_finding_id: finding,
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{state: "invalid", dimension: "event_link"}) do
    %{
      disposition: "blocking_invalid",
      severity: :blocking,
      qualified_finding_id: "contract.blocking_invalid",
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{state: "invalid"} = fact) do
    %{
      disposition: "blocking_invalid",
      severity: :blocking,
      qualified_finding_id: unresolved_finding(fact),
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{state: state})
       when state in ["producer_error", "parser_error"] do
    finding =
      if state == "parser_error", do: "contract.parser_error", else: "contract.contract_violation"

    %{
      disposition: "blocking_error",
      severity: :blocking,
      qualified_finding_id: finding,
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{dimension: "subscription", state: "absent"}) do
    %{
      disposition: "blocking_unknown",
      severity: :blocking,
      qualified_finding_id: "source_risk.subscription_unresolved",
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{
         dimension: "ticket_template",
         state: "absent",
         completeness: completeness
       })
       when completeness != "exhaustive" do
    %{
      disposition: "blocking_unknown",
      severity: :blocking,
      qualified_finding_id: "source_risk.missing_ticket_template",
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(%CanonicalFact{
         dimension: "event_link",
         state: "absent",
         completeness: completeness
       })
       when completeness != "exhaustive" do
    %{
      disposition: "blocking_unknown",
      severity: :blocking,
      qualified_finding_id: "source_risk.missing_tickera_event",
      dimension_local_only?: true
    }
  end

  defp blocking_for_state(_fact), do: nil

  defp unresolved_finding(%CanonicalFact{dimension: "lifecycle"}),
    do: "source_risk.lifecycle_unresolved"

  defp unresolved_finding(%CanonicalFact{dimension: "subscription"}),
    do: "source_risk.subscription_unresolved"

  defp unresolved_finding(%CanonicalFact{dimension: dimension})
       when dimension in ["payment_plan", "membership", "bundle", "add_on"],
       do: "source_risk.#{dimension}"

  defp unresolved_finding(_fact), do: "contract.contract_violation"

  defp finalize(result) do
    disposition = Map.fetch!(result, :disposition)

    unless ContractRegistry.disposition?(disposition) do
      raise ArgumentError, "unknown disposition #{inspect(disposition)}"
    end

    Map.merge(
      %{
        implies_row_safe?: false,
        implies_target_safe?: false,
        implies_plan_safe?: false,
        implies_run_safe?: false,
        implies_apply_eligible?: false
      },
      result
    )
  end
end
