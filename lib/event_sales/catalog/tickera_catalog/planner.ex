defmodule EventSales.Catalog.TickeraCatalog.Planner do
  @moduledoc """
  Converts Tickera catalog discovery into a deterministic dry-run plan.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.TickeraCatalog.{CatalogRow, DiscoveryResult, Finding, Normalizer, Plan}

  @spec plan(Ecto.UUID.t(), DiscoveryResult.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(source_system_id, %DiscoveryResult{} = discovery_result, _opts \\ [])
      when is_binary(source_system_id) do
    with {:ok, %{rows: rows, findings: normalizer_findings}} <-
           Normalizer.normalize(discovery_result),
         {:ok, planned} <- plan_rows(source_system_id, rows) do
      findings =
        normalizer_findings
        |> Enum.concat(planned.findings)
        |> maybe_vwg_preserved(rows, planned)

      snapshot =
        snapshot(%{
          source_system_id: source_system_id,
          event_changes: planned.event_changes,
          ticket_type_changes: planned.ticket_type_changes,
          product_mapping_changes: planned.product_mapping_changes,
          findings: Enum.map(findings, &finding_snapshot/1),
          touched_event_ids: planned.touched_event_ids,
          touched_product_keys: planned.touched_product_keys
        })

      hash = hash_snapshot(snapshot)

      {:ok,
       %Plan{
         event_changes: planned.event_changes,
         ticket_type_changes: planned.ticket_type_changes,
         product_mapping_changes: planned.product_mapping_changes,
         findings: findings,
         touched_event_ids: planned.touched_event_ids,
         touched_product_keys: planned.touched_product_keys,
         summary: summary(snapshot),
         dry_run_hash: hash,
         plan_snapshot: Map.put(snapshot, "dry_run_hash", hash)
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
          source_updated_at: row.event_source_updated_at
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
        {:ok, acc |> touch_event(mapping.event_id) |> touch_product(row)}

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

    event_change = %{
      action: :create,
      ref: event_ref,
      source_system_id: source_system_id,
      name: row.event_title,
      slug: row.event_slug || "tickera-event-#{row.tickera_event_id}",
      status: :active,
      external_event_id: row.tickera_event_id,
      external_event_kind: :tickera_event,
      source_status: row.event_status,
      source_updated_at: row.event_source_updated_at
    }

    ticket_change = %{
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

    {:ok,
     acc
     |> add_event_change(event_change)
     |> add_ticket_change(ticket_change)
     |> add_mapping_change(mapping_change)
     |> touch_product(row)}
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
      "event_change_count" => length(snapshot["event_changes"]),
      "ticket_type_change_count" => length(snapshot["ticket_type_changes"]),
      "product_mapping_change_count" => length(snapshot["product_mapping_changes"]),
      "finding_count" => length(snapshot["findings"])
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
      metadata: %{}
    }
  end

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
  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe({left, right}), do: [json_safe(left), json_safe(right)]
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value
end
