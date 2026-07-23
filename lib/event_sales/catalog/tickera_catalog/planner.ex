defmodule EventSales.Catalog.TickeraCatalog.Planner do
  @moduledoc """
  Converts Tickera catalog discovery into a deterministic dry-run plan.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.EventLifecycle
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}

  alias EventSales.Catalog.TickeraCatalog.{
    CatalogRow,
    DiscoveryResult,
    Finding,
    Normalizer,
    Plan,
    SnapshotCanonicalizer
  }

  alias EventSales.Ingestion.TickeraCatalogHistoricalImpact

  @spec plan(Ecto.UUID.t(), DiscoveryResult.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(source_system_id, %DiscoveryResult{} = discovery_result, opts \\ [])
      when is_binary(source_system_id) do
    with {:ok, %{rows: rows, findings: normalizer_findings, source_risks: source_risks}} <-
           Normalizer.normalize(discovery_result),
         {:ok, planned} <- plan_rows(source_system_id, rows),
         {:ok, historical_impact} <-
           TickeraCatalogHistoricalImpact.forecast(
             source_system_id,
             Map.merge(planned, %{source_snapshot_at: discovery_result.source_snapshot_at}),
             Keyword.get(opts, :historical_impact_opts, [])
           ) do
      findings =
        normalizer_findings
        |> Enum.concat(planned.findings)
        |> maybe_vwg_preserved(rows, planned)

      {snapshot, hash} =
        build_snapshot(
          source_system_id,
          discovery_result,
          planned,
          findings,
          source_risks,
          historical_impact
        )

      {:ok,
       %Plan{
         event_changes: planned.event_changes,
         ticket_type_changes: planned.ticket_type_changes,
         product_mapping_changes: planned.product_mapping_changes,
         findings: findings,
         touched_event_ids: planned.touched_event_ids,
         touched_product_keys: planned.touched_product_keys,
         historical_impact: historical_impact,
         summary: summary(snapshot),
         dry_run_hash: hash,
         plan_snapshot: snapshot
       }}
    end
  end

  defp plan_rows(source_system_id, rows) do
    Enum.reduce_while(rows, {:ok, empty_acc()}, fn row, {:ok, acc} ->
      case plan_row(source_system_id, row, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp plan_row(source_system_id, %CatalogRow{} = row, acc) do
    case existing_active_mapping(source_system_id, row.woo_product_id, row.woo_variation_id) do
      {:ok, %ProductMapping{} = mapping} ->
        plan_existing_mapping(row, mapping, acc)

      {:ok, nil} ->
        plan_new_mapping(source_system_id, row, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plan_existing_mapping(row, mapping, acc) do
    mapping = Ash.load!(mapping, [:event, :ticket_type], domain: Catalog)

    cond do
      is_nil(mapping.event.external_event_id) and
          is_nil(mapping.ticket_type.external_ticket_type_id) ->
        event_change = %{
          action: :adopt_existing,
          event_id: mapping.event_id,
          external_event_id: row.tickera_event_id,
          external_event_kind: :tickera_event,
          source_status: row.event_status,
          source_updated_at: row.event_source_updated_at,
          starts_at: row.starts_at,
          ends_at: row.ends_at,
          venue_name: row.venue_name,
          booking_fee_type: row.booking_fee_type,
          booking_fee_value: row.booking_fee_value
        }

        ticket_change = %{
          action: :adopt_existing,
          ticket_type_id: mapping.ticket_type_id,
          event_id: mapping.event_id,
          external_ticket_type_id: ticket_external_id(row),
          external_ticket_type_kind: row.ticket_type_kind,
          external_product_id: row.woo_product_id,
          external_variation_id: row.woo_variation_id,
          source_status: row.product_status,
          source_updated_at: ticket_source_updated_at(row)
        }

        findings = [
          finding(
            :info,
            :existing_mapping_adopted,
            "Existing active ProductMapping will be adopted.",
            row: row
          )
        ]

        {:ok,
         acc
         |> add_event_change(event_change)
         |> add_ticket_change(ticket_change)
         |> add_findings(findings)
         |> touch_event(mapping.event_id)
         |> touch_product(row)}

      mapping.event.external_event_id == row.tickera_event_id ->
        acc =
          acc
          |> maybe_add_event_metadata_update(mapping.event, row, nil)
          |> touch_event(mapping.event_id)
          |> touch_product(row)

        {:ok, acc}

      true ->
        {:ok,
         add_findings(acc, [
           finding(
             :blocking,
             :existing_mapping_conflict,
             "Active ProductMapping points at a different catalog identity.",
             row: row
           )
         ])}
    end
  end

  defp plan_new_mapping(source_system_id, row, acc) do
    event_ref = "tickera_event:#{row.tickera_event_id}"
    ticket_ref = "#{row.ticket_type_kind}:#{ticket_external_id(row)}"

    with {:ok, event} <- existing_source_event(source_system_id, row),
         {:ok, ticket_type} <- existing_source_ticket_type(event, row) do
      event_change = event_change(source_system_id, row, event_ref, event)
      ticket_change = ticket_change(row, event_ref, ticket_ref, ticket_type)

      mapping_change = %{
        action: :create,
        event_ref: event_ref,
        ticket_type_ref: ticket_ref,
        source_system_id: source_system_id,
        woo_product_id: row.woo_product_id,
        woo_variation_id: row.woo_variation_id,
        original_label: row.ticket_type_name,
        current_label: row.ticket_type_name,
        active: true
      }

      acc =
        acc
        |> add_event_change(event_change)
        |> add_ticket_change(ticket_change)
        |> add_mapping_change(mapping_change)
        |> touch_product(row)

      acc =
        case event do
          %Event{id: event_id} -> touch_event(acc, event_id)
          nil -> acc
        end

      {:ok, acc}
    end
  end

  defp event_change(_source_system_id, row, event_ref, %Event{} = event) do
    if event_metadata_changed?(event, row) do
      event_metadata_change(event, row, event_ref)
    else
      %{
        action: :reuse,
        ref: event_ref,
        event_id: event.id
      }
    end
  end

  defp event_change(source_system_id, row, event_ref, nil) do
    %{
      action: :create,
      ref: event_ref,
      source_system_id: source_system_id,
      name: row.event_title,
      slug: row.event_slug || "tickera-event-#{row.tickera_event_id}",
      status: :active,
      external_event_id: row.tickera_event_id,
      external_event_kind: :tickera_event,
      source_status: row.event_status,
      source_updated_at: row.event_source_updated_at,
      starts_at: row.starts_at,
      ends_at: row.ends_at,
      venue_name: row.venue_name,
      booking_fee_type: row.booking_fee_type,
      booking_fee_value: row.booking_fee_value
    }
  end

  defp maybe_add_event_metadata_update(acc, %Event{} = event, row, event_ref) do
    if event_metadata_changed?(event, row) do
      add_event_change(acc, event_metadata_change(event, row, event_ref))
    else
      acc
    end
  end

  defp event_metadata_change(%Event{} = event, row, event_ref) do
    %{
      action: :update_metadata,
      ref: event_ref,
      event_id: event.id,
      source_status: row.event_status,
      source_updated_at: row.event_source_updated_at,
      starts_at: row.starts_at,
      ends_at: row.ends_at,
      venue_name: row.venue_name,
      booking_fee_type: row.booking_fee_type,
      booking_fee_value: row.booking_fee_value
    }
  end

  defp event_metadata_changed?(%Event{} = event, row) do
    event.source_status != row.event_status or
      compare_datetime(event.source_updated_at, row.event_source_updated_at) or
      compare_datetime(event.starts_at, row.starts_at) or
      compare_datetime(event.ends_at, row.ends_at) or
      event.venue_name != row.venue_name or
      event.booking_fee_type != row.booking_fee_type or
      !decimal_equal?(event.booking_fee_value, row.booking_fee_value)
  end

  defp ticket_change(_row, _event_ref, ticket_ref, %TicketType{} = ticket_type) do
    %{
      action: :reuse,
      ref: ticket_ref,
      ticket_type_id: ticket_type.id
    }
  end

  defp ticket_change(row, event_ref, ticket_ref, nil) do
    %{
      action: :create,
      ref: ticket_ref,
      event_ref: event_ref,
      name: row.ticket_type_name,
      active: true,
      external_ticket_type_id: ticket_external_id(row),
      external_ticket_type_kind: row.ticket_type_kind,
      external_product_id: row.woo_product_id,
      external_variation_id: row.woo_variation_id,
      source_status: row.product_status,
      source_updated_at: ticket_source_updated_at(row)
    }
  end

  defp existing_active_mapping(source_system_id, woo_product_id, nil) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id == ^woo_product_id and
        is_nil(woo_variation_id) and active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp existing_active_mapping(source_system_id, woo_product_id, woo_variation_id) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id == ^woo_product_id and
        woo_variation_id == ^woo_variation_id and active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp existing_source_event(source_system_id, row) do
    Event
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and external_event_kind == :tickera_event and
        external_event_id == ^row.tickera_event_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp existing_source_ticket_type(nil, _row), do: {:ok, nil}

  defp existing_source_ticket_type(%Event{} = event, row) do
    external_ticket_type_id = ticket_external_id(row)

    TicketType
    |> Ash.Query.filter(
      event_id == ^event.id and external_ticket_type_kind == ^row.ticket_type_kind and
        external_ticket_type_id == ^external_ticket_type_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp maybe_vwg_preserved(findings, rows, planned) do
    if Enum.any?(
         rows,
         &(&1.tickera_event_id == 109_316 and &1.woo_product_id == 109_740 and
             is_nil(&1.woo_variation_id))
       ) and
         Enum.any?(
           planned.event_changes,
           &(&1.action == :adopt_existing and &1.external_event_id == 109_316)
         ) do
      [
        finding(
          :info,
          :vwg_pretoria_preserved,
          "VWG Pretoria existing product-level mapping will be preserved.",
          tickera_event_id: 109_316,
          woo_product_id: 109_740
        )
        | findings
      ]
    else
      findings
    end
  end

  defp summary(snapshot) do
    %{
      "event_change_count" => length(snapshot["event_actions"] || snapshot["event_changes"]),
      "ticket_type_change_count" =>
        length(snapshot["ticket_type_actions"] || snapshot["ticket_type_changes"]),
      "product_mapping_change_count" =>
        length(snapshot["product_mapping_actions"] || snapshot["product_mapping_changes"]),
      "finding_count" => length(snapshot["findings"])
    }
  end

  defp build_snapshot(
         source_system_id,
         %DiscoveryResult{schema_version: "2026-07-22.v2"} = discovery,
         planned,
         findings,
         source_risks,
         historical_impact
       ) do
    snapshot = %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_system_id,
      "origin" => Atom.to_string(discovery.origin),
      "event_actions" => json_safe(planned.event_changes),
      "ticket_type_actions" => json_safe(planned.ticket_type_changes),
      "product_mapping_actions" => json_safe(planned.product_mapping_changes),
      "findings" => Enum.map(findings, &v2_finding_snapshot/1),
      "source_risks" => Enum.map(source_risks, &v2_source_risk_snapshot/1),
      "historical_impact" => v2_historical_impact(historical_impact),
      "identity_membership_proof" => identity_membership_proof(planned),
      "touched_identifiers" => touched_identifiers(planned)
    }

    {:ok, _bytes, hash} = SnapshotCanonicalizer.canonicalize(snapshot)
    {snapshot, hash}
  end

  defp build_snapshot(
         source_system_id,
         _discovery,
         planned,
         findings,
         _source_risks,
         historical_impact
       ) do
    snapshot =
      snapshot(%{
        source_system_id: source_system_id,
        event_changes: planned.event_changes,
        ticket_type_changes: planned.ticket_type_changes,
        product_mapping_changes: planned.product_mapping_changes,
        findings: Enum.map(findings, &finding_snapshot/1),
        touched_event_ids: planned.touched_event_ids,
        touched_product_keys: planned.touched_product_keys,
        historical_impact: historical_impact
      })

    hash = hash_snapshot(snapshot)
    {Map.put(snapshot, "dry_run_hash", hash), hash}
  end

  defp v2_finding_snapshot(%Finding{} = finding) do
    {target_type, target_id} =
      cond do
        finding.woo_variation_id -> {"variation", finding.woo_variation_id}
        finding.woo_product_id -> {"product", finding.woo_product_id}
        finding.tickera_event_id -> {"event", finding.tickera_event_id}
        true -> {"run", nil}
      end

    context =
      case finding.metadata["event_lifecycle"] do
        value when value in ["past", "current", "future", "unknown"] ->
          %{"event_lifecycle" => value}

        _other ->
          %{}
      end

    %{
      "severity" => Atom.to_string(finding.severity),
      "code" => Atom.to_string(finding.code),
      "target_type" => target_type,
      "target_id" => target_id,
      "context" => context
    }
  end

  defp v2_source_risk_snapshot(risk) do
    %{
      "target_type" => Atom.to_string(risk.target_type),
      "target_id" => risk.target_id,
      "code" => Atom.to_string(risk.code),
      "evidence_classification" => Atom.to_string(risk.evidence_classification),
      "evidence_source" => Atom.to_string(risk.evidence_source),
      "evidence_value" => risk.evidence_value
    }
  end

  defp v2_historical_impact(impact) do
    destinations =
      Enum.map(impact["proposed_destinations"] || [], fn destination ->
        %{
          "woo_product_id" => destination["woo_product_id"],
          "woo_variation_id" => destination["woo_variation_id"],
          "proposed_event_external_id" => destination["proposed_event_external_id"],
          "proposed_ticket_type_external_id" => destination["proposed_ticket_type_external_id"],
          "resolution" => destination["resolution"],
          "pending_line_count" => 0,
          "quantity" => 0,
          "eligible_line_count" => 0,
          "deferred_line_count" => 0,
          "conflicting_line_count" => 0,
          "conflicting_quantity" => 0,
          "already_mapped_line_count" => 0,
          "already_mapped_quantity" => 0,
          "unknown_classification_count" => 0
        }
      end)

    %{
      "totals" => impact["totals"],
      "warning_count" => length(impact["warnings"] || []),
      "unresolved_destination_count" =>
        Enum.count(destinations, &(&1["resolution"] in ["missing_destination", "conflict"])),
      "unknown_classification_count" => 0,
      "destinations" => destinations
    }
  end

  defp identity_membership_proof(planned) do
    %{
      "events" => Enum.map(planned.event_changes, &event_proof/1),
      "ticket_types" => Enum.map(planned.ticket_type_changes, &ticket_type_proof/1),
      "product_mappings" => Enum.map(planned.product_mapping_changes, &mapping_proof/1)
    }
    |> json_safe()
  end

  defp event_proof(change) do
    %{
      source_system_id: change[:source_system_id],
      external_event_kind: change[:external_event_kind],
      external_event_id: change[:external_event_id],
      event_id: change[:event_id],
      action: change.action,
      no_mutation: change.action == :reuse
    }
  end

  defp ticket_type_proof(change) do
    %{
      external_ticket_type_kind: change[:external_ticket_type_kind],
      external_ticket_type_id: change[:external_ticket_type_id],
      external_product_id: change[:external_product_id],
      external_variation_id: change[:external_variation_id],
      ticket_type_id: change[:ticket_type_id],
      event_id: change[:event_id],
      event_ref: change[:event_ref],
      action: change.action,
      no_mutation: change.action == :reuse
    }
  end

  defp mapping_proof(change) do
    %{
      source_system_id: change.source_system_id,
      woo_product_id: change.woo_product_id,
      woo_variation_id: change.woo_variation_id,
      event_ref: change.event_ref,
      ticket_type_ref: change.ticket_type_ref,
      action: change.action,
      no_existing_conflict: true,
      no_movement: true
    }
  end

  defp touched_identifiers(planned) do
    %{
      "event_ids" => planned.touched_event_ids,
      "ticket_type_ids" =>
        planned.ticket_type_changes
        |> Enum.map(& &1[:ticket_type_id])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      "mapping_ids" => [],
      "product_keys" =>
        Enum.map(planned.touched_product_keys, fn {product_id, variation_id} ->
          %{"woo_product_id" => product_id, "woo_variation_id" => variation_id}
        end)
    }
  end

  defp snapshot(map), do: json_safe(map)

  defp hash_snapshot(snapshot) do
    snapshot
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp ticket_external_id(%{ticket_type_kind: :woo_variation, woo_variation_id: variation_id}),
    do: variation_id

  defp ticket_external_id(%{woo_product_id: product_id}), do: product_id

  defp ticket_source_updated_at(%{ticket_type_kind: :woo_variation} = row),
    do: row.variation_source_updated_at || row.product_source_updated_at

  defp ticket_source_updated_at(row), do: row.product_source_updated_at

  defp finding(severity, code, message, opts) do
    row = Keyword.get(opts, :row)

    %Finding{
      severity: severity,
      code: code,
      message: message,
      tickera_event_id: Keyword.get(opts, :tickera_event_id) || (row && row.tickera_event_id),
      woo_product_id: Keyword.get(opts, :woo_product_id) || (row && row.woo_product_id),
      woo_variation_id: Keyword.get(opts, :woo_variation_id) || (row && row.woo_variation_id),
      metadata: finding_metadata(row)
    }
  end

  defp finding_metadata(nil), do: %{}

  defp finding_metadata(row) do
    case EventLifecycle.classify(row) do
      :past ->
        %{
          "event_lifecycle" => "past",
          "review_context" => "past_event_with_catalog_issue"
        }

      lifecycle ->
        %{"event_lifecycle" => Atom.to_string(lifecycle)}
    end
  end

  defp compare_datetime(nil, nil), do: false

  defp compare_datetime(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) != :eq

  defp compare_datetime(left, right), do: left != right

  defp decimal_equal?(nil, nil), do: true
  defp decimal_equal?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)
  defp decimal_equal?(left, right), do: left == right

  defp finding_snapshot(%Finding{} = finding), do: Map.from_struct(finding)

  defp empty_acc,
    do: %{
      event_changes: [],
      ticket_type_changes: [],
      product_mapping_changes: [],
      findings: [],
      touched_event_ids: [],
      touched_product_keys: []
    }

  defp add_event_change(acc, change),
    do: Map.update!(acc, :event_changes, &unique_append(&1, change))

  defp add_ticket_change(acc, change),
    do: Map.update!(acc, :ticket_type_changes, &unique_append(&1, change))

  defp add_mapping_change(acc, change),
    do: Map.update!(acc, :product_mapping_changes, &unique_append(&1, change))

  defp add_findings(acc, findings), do: Map.update!(acc, :findings, &(&1 ++ findings))

  defp touch_event(acc, event_id),
    do: Map.update!(acc, :touched_event_ids, &Enum.uniq([event_id | &1]))

  defp touch_product(acc, row),
    do:
      Map.update!(
        acc,
        :touched_product_keys,
        &Enum.uniq([{row.woo_product_id, row.woo_variation_id} | &1])
      )

  defp unique_append(values, value), do: if(value in values, do: values, else: values ++ [value])

  defp json_safe(nil), do: nil
  defp json_safe(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe({left, right}), do: [json_safe(left), json_safe(right)]
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value
end
