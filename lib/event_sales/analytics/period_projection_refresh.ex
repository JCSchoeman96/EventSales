defmodule EventSales.Analytics.PeriodProjectionRefresh do
  @moduledoc false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Analytics.PeriodDimensionAggregator
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.Sales.FinancialPrimitives

  @period_table "analytics_event_period_aggregate_snapshots"
  @dimension_table "analytics_event_dimension_period_aggregate_snapshots"
  @contribution_table "analytics_contribution_facts"
  @coverage_identity "m5_04d:event_period_bucket_v1"
  @semantic_version 1
  @zero Decimal.new("0")

  @fact_truth_fields [
    :contribution_kind,
    :source_contribution_id,
    :event_id,
    :currency,
    :effective_at,
    :ticket_type_id,
    :source_system_id,
    :woo_product_id,
    :woo_variation_id,
    :gross_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_quantity,
    :refund_ticket_value
  ]
  @decimal_fact_fields [:gross_ticket_value, :refund_ticket_value]

  @doc false
  @spec refresh_pending_event(Ecto.UUID.t() | String.t(), keyword()) :: :ok | {:error, term()}
  def refresh_pending_event(event_id, opts \\ [])

  def refresh_pending_event(event_id, opts) when is_binary(event_id) do
    with true <- Repo.in_transaction?(),
         {:ok, event_id} <- cast_uuid(event_id),
         {:ok, pending_rows} <- pending_rows(event_id),
         :ok <- refresh_pending_rows(event_id, pending_rows, opts) do
      :ok
    else
      false -> {:error, :period_refresh_requires_transaction}
      {:error, reason} -> rollback_or_return(reason)
    end
  rescue
    _error -> rollback_or_return(:period_projection_refresh_failed)
  end

  def refresh_pending_event(_event_id, _opts), do: {:error, :invalid_event_id}

  defp rollback_or_return(reason) do
    if Repo.in_transaction?(), do: Repo.rollback(reason), else: {:error, reason}
  end

  @doc false
  @spec sale_population_query(Ecto.UUID.t() | String.t(), [map()]) :: Ecto.Query.t()
  def sale_population_query(event_id, windows) when is_binary(event_id) and is_list(windows) do
    sale_filter = EventAggregator.recognised_sale_item_filters(Ecto.UUID.dump!(event_id))
    window_filter = sale_window_filter(windows)

    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      left_join: e in "catalog_events",
      on: e.id == oi.event_id,
      left_join: tt in "catalog_ticket_types",
      on: tt.id == oi.ticket_type_id,
      where: ^dynamic([oi, o], ^sale_filter and ^window_filter),
      order_by: oi.id,
      select: %{
        id: oi.id,
        event_id: oi.event_id,
        currency: o.currency,
        effective_at:
          type(fragment("COALESCE(?, ?)", o.paid_at, o.completed_at), :utc_datetime_usec),
        ticket_type_id: oi.ticket_type_id,
        source_system_id: o.source_system_id,
        event_source_system_id: e.source_system_id,
        ticket_type_event_id: tt.event_id,
        woo_product_id: oi.woo_product_id,
        woo_variation_id: oi.woo_variation_id,
        quantity: oi.quantity,
        line_total: oi.line_total,
        line_total_tax: oi.line_total_tax,
        source_watermark_at: o.updated_at_source
      }
  end

  @doc false
  @spec refund_population_query(Ecto.UUID.t() | String.t(), [map()]) :: Ecto.Query.t()
  def refund_population_query(event_id, windows) when is_binary(event_id) and is_list(windows) do
    refund_filter = EventAggregator.refund_primitives_filters()
    window_filter = refund_window_filter(windows)

    from rl in "sales_refund_lines",
      join: r in "sales_refunds",
      on: rl.refund_id == r.id,
      join: o in "sales_orders",
      on: r.order_id == o.id,
      join: parent in "sales_order_items",
      on:
        parent.id == rl.order_item_id and parent.order_id == o.id and
          parent.woo_line_item_id == rl.woo_refunded_item_id,
      left_join: e in "catalog_events",
      on: e.id == parent.event_id,
      left_join: tt in "catalog_ticket_types",
      on: tt.id == parent.ticket_type_id,
      where:
        ^dynamic(
          [rl, r, o, parent],
          parent.event_id == type(^event_id, Ecto.UUID) and
            parent.mapping_status == "mapped" and parent.item_kind == "ticket" and
            ^refund_filter and ^window_filter
        ),
      order_by: rl.id,
      select: %{
        id: rl.id,
        event_id: parent.event_id,
        currency: r.currency,
        effective_at: r.source_created_at,
        ticket_type_id: parent.ticket_type_id,
        source_system_id: o.source_system_id,
        event_source_system_id: e.source_system_id,
        ticket_type_event_id: tt.event_id,
        woo_product_id: parent.woo_product_id,
        woo_variation_id: parent.woo_variation_id,
        refunded_quantity: rl.refunded_quantity,
        refund_total_amount: rl.refund_total_amount,
        refund_total_tax: rl.refund_total_tax,
        source_watermark_at: o.updated_at_source
      }
  end

  @doc false
  @spec dimension_delete_query(atom(), [map()]) :: Ecto.Query.t()
  def dimension_delete_query(dimension_kind, pending_rows)
      when dimension_kind in [:ticket_type, :source_product, :source_variation] and
             is_list(pending_rows) do
    case pending_rows do
      [] ->
        from dimension in @dimension_table, where: false

      [_first | _rest] ->
        dimension_kind = Atom.to_string(dimension_kind)
        bucket_filter = pending_dimension_bucket_filter(pending_rows, dimension_kind)

        from dimension in @dimension_table,
          where: ^bucket_filter
    end
  end

  defp refresh_pending_rows(_event_id, [], _opts), do: :ok

  defp refresh_pending_rows(event_id, pending_rows, opts) do
    pending_day_rows = Enum.filter(pending_rows, &(&1.bucket_kind == :johannesburg_day))
    hour_rows = Enum.filter(pending_rows, &(&1.bucket_kind == :utc_hour))

    day_rows =
      pending_day_rows ++
        current_johannesburg_envelopes_for_pending_hours(event_id, hour_rows, pending_day_rows)

    with :ok <- validate_day_coverage(day_rows, hour_rows),
         windows = coverage_windows(day_rows),
         {:ok, sales_rows} <- fetch_sales(event_id, windows),
         {:ok, refund_rows} <- fetch_refunds(event_id, windows),
         {:ok, current_facts} <- normalize_contributions(sales_rows, refund_rows),
         {:ok, totals_by_bucket} <- aggregate_bucket_totals(current_facts),
         {:ok, dimensional_rows} <-
           PeriodDimensionAggregator.rows_for_pending_buckets(current_facts, pending_rows),
         {:ok, variation_totals_by_bucket} <-
           PeriodDimensionAggregator.variation_subset_totals_for_pending_buckets(
             current_facts,
             pending_rows
           ),
         :ok <-
           PeriodDimensionAggregator.reconcile_rows(
             dimensional_rows,
             pending_rows,
             totals_by_bucket,
             variation_totals_by_bucket
           ),
         {:ok, existing_facts} <- existing_contributions(event_id, windows),
         {:ok, changed_facts, removed_facts} <- exact_diff(existing_facts, current_facts),
         generation_id = Ecto.UUID.generate(),
         refreshed_at = refreshed_at(opts),
         {:ok, source_watermark_at} <- source_watermark(sales_rows ++ refund_rows),
         :ok <-
           persist_contribution_diff(
             changed_facts,
             removed_facts,
             generation_id,
             refreshed_at,
             source_watermark_at
           ) do
      with :ok <-
             replace_pending_dimensions(
               pending_rows,
               dimensional_rows,
               generation_id,
               refreshed_at,
               source_watermark_at,
               opts
             ) do
        replace_pending_buckets(
          pending_rows,
          totals_by_bucket,
          generation_id,
          refreshed_at,
          source_watermark_at
        )
      end
    end
  end

  defp pending_rows(event_id) do
    EventPeriodAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and projection_state in [:refresh_pending, :stale])
    |> Ash.Query.sort(currency: :asc, bucket_kind: :asc, bucket_start_utc: :asc)
    |> Ash.read(domain: Analytics)
    |> case do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, :pending_period_rows_read_failed}
    end
  end

  defp current_johannesburg_envelopes_for_pending_hours(event_id, hour_rows, pending_day_rows) do
    identities = johannesburg_identity_keys_for_uncovered_hours(hour_rows, pending_day_rows)

    case identities do
      [] -> []
      keys -> read_current_johannesburg_envelopes(event_id, keys)
    end
  end

  defp johannesburg_identity_keys_for_uncovered_hours(hour_rows, pending_day_rows) do
    hour_rows
    |> Enum.reject(&hour_covered_by_pending_day?(&1, pending_day_rows))
    |> Enum.flat_map(&johannesburg_identity_keys_for_hour/1)
    |> Enum.uniq()
  end

  defp hour_covered_by_pending_day?(hour, pending_day_rows) do
    Enum.any?(pending_day_rows, &johannesburg_day_envelopes_hour?(&1, hour))
  end

  defp johannesburg_identity_keys_for_hour(hour) do
    case PeriodBucketRules.for_instant(hour.bucket_start_utc) do
      {:ok, buckets} ->
        buckets
        |> Enum.filter(&(&1.bucket_kind == :johannesburg_day))
        |> Enum.map(fn day -> {hour.currency, day.bucket_start_utc, day.bucket_end_utc} end)

      {:error, _} ->
        []
    end
  end

  @doc false
  @spec current_johannesburg_envelope_query(Ecto.UUID.t(), [
          {String.t(), DateTime.t(), DateTime.t()}
        ]) :: Ecto.Query.t()
  def current_johannesburg_envelope_query(event_id, identities) when is_list(identities) do
    currencies = Enum.map(identities, fn {currency, _, _} -> currency end)
    starts = Enum.map(identities, fn {_, start_utc, _} -> start_utc end)
    ends = Enum.map(identities, fn {_, _, end_utc} -> end_utc end)

    from(row in EventPeriodAggregateSnapshot,
      where: row.event_id == ^event_id,
      where: row.projection_state == :current,
      where: row.bucket_kind == :johannesburg_day,
      where:
        fragment(
          "(?, ?, ?) IN (SELECT * FROM unnest(?::varchar[], ?::timestamptz[], ?::timestamptz[]))",
          row.currency,
          row.bucket_start_utc,
          row.bucket_end_utc,
          ^currencies,
          ^starts,
          ^ends
        )
    )
  end

  defp read_current_johannesburg_envelopes(event_id, identities) when is_list(identities) do
    event_id
    |> current_johannesburg_envelope_query(identities)
    |> Repo.all()
  end

  defp johannesburg_day_envelopes_hour?(day_row, hour_row) do
    day_row.currency == hour_row.currency and
      DateTime.compare(day_row.bucket_start_utc, hour_row.bucket_start_utc) in [:lt, :eq] and
      DateTime.compare(day_row.bucket_end_utc, hour_row.bucket_end_utc) in [:gt, :eq]
  end

  defp validate_day_coverage([], []), do: {:error, :missing_johannesburg_day_coverage}

  defp validate_day_coverage(day_rows, hour_rows) do
    complete? =
      Enum.all?(hour_rows, fn hour ->
        Enum.any?(day_rows, fn day ->
          day.currency == hour.currency and
            DateTime.compare(day.bucket_start_utc, hour.bucket_start_utc) in [:lt, :eq] and
            DateTime.compare(day.bucket_end_utc, hour.bucket_end_utc) in [:gt, :eq]
        end)
      end)

    if day_rows != [] and complete?, do: :ok, else: {:error, :missing_johannesburg_day_coverage}
  end

  defp coverage_windows(day_rows) do
    day_rows
    |> Enum.map(fn row ->
      %{
        currency: row.currency,
        start_utc: row.bucket_start_utc,
        end_utc: row.bucket_end_utc
      }
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn window ->
      {window.currency, DateTime.to_unix(window.start_utc, :microsecond)}
    end)
  end

  defp fetch_sales(_event_id, []), do: {:ok, []}

  defp fetch_sales(event_id, windows) do
    rows = Repo.all(sale_population_query(event_id, windows))
    {:ok, rows}
  rescue
    _error -> {:error, :sale_population_query_failed}
  end

  defp fetch_refunds(_event_id, []), do: {:ok, []}

  defp fetch_refunds(event_id, windows) do
    rows = Repo.all(refund_population_query(event_id, windows))
    {:ok, rows}
  rescue
    _error -> {:error, :refund_population_query_failed}
  end

  defp normalize_contributions(sales_rows, refund_rows) do
    with {:ok, sales} <- normalize_sales(sales_rows),
         {:ok, refunds} <- normalize_refunds(refund_rows) do
      {:ok, sales ++ refunds}
    end
  end

  defp normalize_sales(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case normalize_sale(row) do
        {:ok, fact} -> {:cont, {:ok, [fact | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_sale(
         %{line_total: %Decimal{} = line_total, line_total_tax: %Decimal{} = tax} = row
       ) do
    with {:ok, identity} <- normalize_identity(row) do
      {:ok,
       Map.merge(identity, %{
         contribution_kind: :sale,
         gross_ticket_quantity: row.quantity,
         gross_ticket_value: FinancialPrimitives.gross_ticket_value(line_total, tax),
         refund_ticket_quantity: 0,
         refund_ticket_value: @zero,
         source_watermark_at: row.source_watermark_at
       })}
    end
  end

  defp normalize_sale(_row), do: {:error, :incomplete_financial_primitives}

  defp normalize_refunds(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case normalize_refund(row) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, fact} -> {:cont, {:ok, [fact | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_refund(
         %{
           refunded_quantity: quantity,
           refund_total_amount: %Decimal{} = amount,
           refund_total_tax: %Decimal{} = tax
         } = row
       ) do
    with {:ok, identity} <- normalize_identity(row) do
      refund_quantity = FinancialPrimitives.refund_ticket_quantity(quantity)
      refund_value = FinancialPrimitives.refund_ticket_value(amount, tax)

      if Decimal.compare(refund_quantity, @zero) == :gt or
           Decimal.compare(refund_value, @zero) == :gt do
        {:ok,
         Map.merge(identity, %{
           contribution_kind: :refund,
           gross_ticket_quantity: 0,
           gross_ticket_value: @zero,
           refund_ticket_quantity: Decimal.to_integer(refund_quantity),
           refund_ticket_value: refund_value,
           source_watermark_at: row.source_watermark_at
         })}
      else
        {:ok, nil}
      end
    end
  end

  defp normalize_refund(_row), do: {:error, :invalid_refund_primitives}

  defp normalize_identity(row) do
    with {:ok, source_contribution_id} <- uuid_from_repo(row.id),
         {:ok, event_id} <- uuid_from_repo(row.event_id),
         {:ok, ticket_type_id} <- uuid_from_repo(row.ticket_type_id),
         {:ok, source_system_id} <- uuid_from_repo(row.source_system_id),
         :ok <- identity_matches(row.ticket_type_event_id, event_id, :ticket_type_event_mismatch),
         :ok <-
           identity_matches(
             row.event_source_system_id,
             source_system_id,
             :event_source_system_mismatch
           ),
         :ok <- valid_currency(row.currency),
         {:ok, effective_at} <- utc_datetime(row.effective_at),
         :ok <- valid_product_identity(row.woo_product_id, row.woo_variation_id) do
      {:ok,
       %{
         source_contribution_id: source_contribution_id,
         event_id: event_id,
         currency: row.currency,
         effective_at: effective_at,
         ticket_type_id: ticket_type_id,
         source_system_id: source_system_id,
         woo_product_id: row.woo_product_id,
         woo_variation_id: row.woo_variation_id
       }}
    end
  end

  defp existing_contributions(_event_id, []), do: {:ok, []}

  defp existing_contributions(event_id, windows) do
    window_filter = fact_window_filter(windows)

    query =
      from fact in @contribution_table,
        where:
          ^dynamic(
            [fact],
            fact.event_id == type(^event_id, Ecto.UUID) and ^window_filter
          ),
        select: %{
          id: fact.id,
          contribution_kind: fact.contribution_kind,
          source_contribution_id: fact.source_contribution_id,
          event_id: fact.event_id,
          currency: fact.currency,
          effective_at: fact.effective_at,
          ticket_type_id: fact.ticket_type_id,
          source_system_id: fact.source_system_id,
          woo_product_id: fact.woo_product_id,
          woo_variation_id: fact.woo_variation_id,
          gross_ticket_quantity: fact.gross_ticket_quantity,
          gross_ticket_value: fact.gross_ticket_value,
          refund_ticket_quantity: fact.refund_ticket_quantity,
          refund_ticket_value: fact.refund_ticket_value,
          generation_id: fact.generation_id,
          semantic_version: fact.semantic_version,
          coverage_identity: fact.coverage_identity,
          refreshed_at: fact.refreshed_at,
          source_watermark_at: fact.source_watermark_at,
          inserted_at: fact.inserted_at,
          updated_at: fact.updated_at
        }

    Repo.all(query)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case normalize_existing_fact(row) do
        {:ok, fact} -> {:cont, {:ok, [fact | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  rescue
    _error -> {:error, :contribution_fact_read_failed}
  end

  defp normalize_existing_fact(row) do
    with {:ok, id} <- uuid_from_repo(row.id),
         {:ok, source_contribution_id} <- uuid_from_repo(row.source_contribution_id),
         {:ok, event_id} <- uuid_from_repo(row.event_id),
         {:ok, ticket_type_id} <- uuid_from_repo(row.ticket_type_id),
         {:ok, source_system_id} <- uuid_from_repo(row.source_system_id),
         {:ok, generation_id} <- uuid_from_repo(row.generation_id),
         {:ok, effective_at} <- utc_datetime(row.effective_at),
         {:ok, contribution_kind} <- contribution_kind(row.contribution_kind) do
      {:ok,
       row
       |> Map.merge(%{
         id: id,
         source_contribution_id: source_contribution_id,
         event_id: event_id,
         ticket_type_id: ticket_type_id,
         source_system_id: source_system_id,
         generation_id: generation_id,
         effective_at: effective_at,
         contribution_kind: contribution_kind
       })}
    end
  end

  defp exact_diff(existing, current) do
    existing_by_key = Map.new(existing, &{fact_key(&1), &1})
    current_by_key = Map.new(current, &{fact_key(&1), &1})

    changed =
      Enum.flat_map(current_by_key, fn {key, fact} ->
        changed_current_fact(existing_by_key, key, fact)
      end)

    removed =
      Enum.flat_map(existing_by_key, fn {key, fact} ->
        if Map.has_key?(current_by_key, key), do: [], else: [fact]
      end)

    {:ok, changed, removed}
  end

  defp changed_current_fact(existing_by_key, key, fact) do
    case Map.get(existing_by_key, key) do
      nil -> [fact]
      previous -> if same_fact_truth?(previous, fact), do: [], else: [fact]
    end
  end

  defp same_fact_truth?(left, right) do
    metadata_current? =
      Map.get(left, :semantic_version) == @semantic_version and
        Map.get(left, :coverage_identity) == @coverage_identity

    metadata_current? and
      Enum.all?(@fact_truth_fields, fn field ->
        left_value = Map.get(left, field)
        right_value = Map.get(right, field)

        if field in @decimal_fact_fields and match?(%Decimal{}, left_value) and
             match?(%Decimal{}, right_value) do
          Decimal.equal?(left_value, right_value)
        else
          left_value == right_value
        end
      end)
  end

  defp fact_key(fact), do: {fact.contribution_kind, fact.source_contribution_id}

  defp persist_contribution_diff([], [], _generation_id, _refreshed_at, _watermark), do: :ok

  defp persist_contribution_diff(changed, removed, generation_id, refreshed_at, watermark) do
    persisted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with :ok <-
           persist_changed_facts(changed, generation_id, refreshed_at, watermark, persisted_at) do
      delete_removed_facts(removed)
    end
  rescue
    _error -> {:error, :contribution_fact_persist_failed}
  end

  defp persist_changed_facts([], _generation_id, _refreshed_at, _watermark, _persisted_at),
    do: :ok

  defp persist_changed_facts(changed, generation_id, refreshed_at, watermark, persisted_at) do
    rows =
      Enum.map(changed, fn fact ->
        fact
        |> Map.take(@fact_truth_fields)
        |> Map.merge(%{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          contribution_kind: Atom.to_string(fact.contribution_kind),
          source_contribution_id: Ecto.UUID.dump!(fact.source_contribution_id),
          event_id: Ecto.UUID.dump!(fact.event_id),
          ticket_type_id: Ecto.UUID.dump!(fact.ticket_type_id),
          source_system_id: Ecto.UUID.dump!(fact.source_system_id),
          generation_id: Ecto.UUID.dump!(generation_id),
          semantic_version: @semantic_version,
          coverage_identity: @coverage_identity,
          refreshed_at: refreshed_at,
          source_watermark_at: watermark,
          inserted_at: persisted_at,
          updated_at: persisted_at
        })
      end)

    update_fields =
      (@fact_truth_fields -- [:contribution_kind, :source_contribution_id])
      |> Kernel.++([
        :generation_id,
        :semantic_version,
        :coverage_identity,
        :refreshed_at,
        :source_watermark_at,
        :updated_at
      ])

    {count, _rows} =
      Repo.insert_all(@contribution_table, rows,
        on_conflict: {:replace, update_fields},
        conflict_target: [:contribution_kind, :source_contribution_id]
      )

    if count == length(rows), do: :ok, else: {:error, :contribution_fact_write_count_mismatch}
  end

  defp delete_removed_facts([]), do: :ok

  defp delete_removed_facts(removed) do
    ids = Enum.map(removed, &Ecto.UUID.dump!(&1.id))
    expected_event_id = removed |> hd() |> Map.fetch!(:event_id) |> Ecto.UUID.dump!()

    {_count, _rows} =
      from(fact in @contribution_table,
        where: fact.id in ^ids and fact.event_id == ^expected_event_id
      )
      |> Repo.delete_all()

    :ok
  end

  defp replace_pending_buckets(
         pending_rows,
         totals_by_bucket,
         generation_id,
         refreshed_at,
         watermark
       ) do
    persisted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(pending_rows, fn bucket ->
        totals =
          Map.get(totals_by_bucket, bucket_identity_key(bucket)) ||
            FinancialPrimitives.empty_totals()

        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          event_id: Ecto.UUID.dump!(bucket.event_id),
          currency: bucket.currency,
          bucket_kind: Atom.to_string(bucket.bucket_kind),
          bucket_start_utc: bucket.bucket_start_utc,
          bucket_end_utc: bucket.bucket_end_utc,
          bucket_timezone: bucket.bucket_timezone,
          gross_ticket_quantity: totals.gross_ticket_quantity |> Decimal.to_integer(),
          gross_ticket_value: totals.gross_ticket_value,
          refund_ticket_quantity: totals.refund_ticket_quantity |> Decimal.to_integer(),
          refund_ticket_value: totals.refund_ticket_value,
          generation_id: Ecto.UUID.dump!(generation_id),
          semantic_version: @semantic_version,
          coverage_identity: @coverage_identity,
          projection_state: "current",
          refreshed_at: refreshed_at,
          source_watermark_at: watermark,
          inserted_at: persisted_at,
          updated_at: persisted_at
        }
      end)

    update_fields = [
      :gross_ticket_quantity,
      :gross_ticket_value,
      :refund_ticket_quantity,
      :refund_ticket_value,
      :generation_id,
      :semantic_version,
      :coverage_identity,
      :projection_state,
      :refreshed_at,
      :source_watermark_at,
      :updated_at
    ]

    {count, _rows} =
      Repo.insert_all(@period_table, rows,
        on_conflict: {:replace, update_fields},
        conflict_target: [
          :event_id,
          :currency,
          :bucket_kind,
          :bucket_start_utc,
          :bucket_end_utc
        ]
      )

    if count == length(rows), do: :ok, else: {:error, :period_bucket_write_count_mismatch}
  rescue
    _error -> {:error, :period_bucket_persist_failed}
  end

  defp replace_pending_dimensions(
         pending_rows,
         dimensional_rows,
         generation_id,
         refreshed_at,
         watermark,
         opts
       ) do
    failure = Keyword.get(opts, :dimension_persist_failure)

    with :ok <-
           delete_dimension_family_rows(
             :ticket_type,
             pending_rows,
             failure
           ),
         :ok <-
           delete_dimension_family_rows(
             :source_product,
             pending_rows,
             failure
           ),
         :ok <-
           delete_dimension_family_rows(
             :source_variation,
             pending_rows,
             failure
           ) do
      bulk_insert_dimension_rows(
        dimensional_rows,
        generation_id,
        refreshed_at,
        watermark,
        failure
      )
    end
  rescue
    _error -> {:error, :dimension_snapshot_persist_failed}
  end

  defp delete_dimension_family_rows(dimension_kind, pending_rows, failure) do
    if dimension_persist_failure?(failure, :delete, dimension_kind) do
      {:error, {:dimension_persist_injected_failure, :delete, dimension_kind}}
    else
      query = dimension_delete_query(dimension_kind, pending_rows)

      try do
        Repo.delete_all(query)
        :ok
      rescue
        _error -> {:error, :dimension_snapshot_persist_failed}
      end
    end
  end

  defp bulk_insert_dimension_rows([], _generation_id, _refreshed_at, _watermark, _failure),
    do: :ok

  defp bulk_insert_dimension_rows(
         dimensional_rows,
         generation_id,
         refreshed_at,
         watermark,
         failure
       ) do
    if dimension_persist_failure?(failure, :insert, nil) do
      {:error, {:dimension_persist_injected_failure, :insert}}
    else
      persisted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows =
        Enum.map(dimensional_rows, fn row ->
          %{
            id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
            event_id: Ecto.UUID.dump!(row.event_id),
            currency: row.currency,
            bucket_kind: Atom.to_string(row.bucket_kind),
            bucket_start_utc: row.bucket_start_utc,
            bucket_end_utc: row.bucket_end_utc,
            bucket_timezone: row.bucket_timezone,
            dimension_kind: Atom.to_string(row.dimension_kind),
            ticket_type_id: dump_optional_uuid(row.ticket_type_id),
            source_system_id: dump_optional_uuid(row.source_system_id),
            woo_product_id: row.woo_product_id,
            woo_variation_id: row.woo_variation_id,
            gross_ticket_quantity: row.gross_ticket_quantity,
            gross_ticket_value: row.gross_ticket_value,
            refund_ticket_quantity: row.refund_ticket_quantity,
            refund_ticket_value: row.refund_ticket_value,
            generation_id: Ecto.UUID.dump!(generation_id),
            semantic_version: @semantic_version,
            coverage_identity: @coverage_identity,
            projection_state: "current",
            refreshed_at: refreshed_at,
            source_watermark_at: watermark,
            inserted_at: persisted_at,
            updated_at: persisted_at
          }
        end)

      try do
        {count, _rows} = Repo.insert_all(@dimension_table, rows)

        if count == length(rows),
          do: :ok,
          else: {:error, :dimension_snapshot_insert_count_mismatch}
      rescue
        _error -> {:error, :dimension_snapshot_persist_failed}
      end
    end
  end

  defp dimension_persist_failure?(failure, :insert, _dimension_kind), do: failure == :insert

  defp dimension_persist_failure?(failure, :delete, dimension_kind) do
    failure in [dimension_kind, {"delete", dimension_kind}, {:delete, dimension_kind}]
  end

  defp pending_dimension_bucket_filter(pending_rows, dimension_kind) do
    Enum.reduce(pending_rows, dynamic(false), fn bucket, acc ->
      event_id = bucket |> Map.fetch!(:event_id) |> Ecto.UUID.dump!()
      currency = Map.fetch!(bucket, :currency)
      bucket_kind = bucket |> Map.fetch!(:bucket_kind) |> Atom.to_string()
      bucket_start_utc = Map.fetch!(bucket, :bucket_start_utc)
      bucket_end_utc = Map.fetch!(bucket, :bucket_end_utc)

      dynamic(
        [dimension],
        ^acc or
          (dimension.event_id == ^event_id and
             dimension.dimension_kind == ^dimension_kind and
             dimension.currency == ^currency and
             dimension.bucket_kind == ^bucket_kind and
             dimension.bucket_start_utc == ^bucket_start_utc and
             dimension.bucket_end_utc == ^bucket_end_utc)
      )
    end)
  end

  defp dump_optional_uuid(nil), do: nil
  defp dump_optional_uuid(id), do: Ecto.UUID.dump!(id)

  defp aggregate_bucket_totals(facts) do
    Enum.reduce_while(facts, {:ok, %{}}, fn fact, {:ok, totals_by_bucket} ->
      case PeriodBucketRules.for_instant(fact.effective_at) do
        {:ok, buckets} ->
          {:cont, {:ok, add_fact_to_buckets(totals_by_bucket, fact, buckets)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp add_fact_to_buckets(totals_by_bucket, fact, buckets) do
    Enum.reduce(buckets, totals_by_bucket, fn bucket, acc ->
      key =
        bucket_identity_key(
          Map.merge(bucket, %{event_id: fact.event_id, currency: fact.currency})
        )

      totals = Map.get(acc, key, FinancialPrimitives.empty_totals())
      Map.put(acc, key, add_contribution_totals(fact, totals))
    end)
  end

  defp bucket_identity_key(bucket) do
    {bucket.event_id, bucket.currency, bucket.bucket_kind, bucket.bucket_start_utc,
     bucket.bucket_end_utc}
  end

  defp add_contribution_totals(%{contribution_kind: :sale} = fact, totals) do
    contribution_totals =
      FinancialPrimitives.empty_totals()
      |> Map.put(
        :gross_ticket_quantity,
        FinancialPrimitives.gross_ticket_quantity(fact.gross_ticket_quantity)
      )
      |> Map.put(:gross_ticket_value, fact.gross_ticket_value)

    FinancialPrimitives.add_totals(totals, contribution_totals)
  end

  defp add_contribution_totals(%{contribution_kind: :refund} = fact, totals) do
    contribution_totals =
      FinancialPrimitives.empty_totals()
      |> Map.put(
        :refund_ticket_quantity,
        FinancialPrimitives.refund_ticket_quantity(fact.refund_ticket_quantity)
      )
      |> Map.put(:refund_ticket_value, fact.refund_ticket_value)

    FinancialPrimitives.add_totals(totals, contribution_totals)
  end

  defp sale_window_filter(windows) do
    Enum.reduce(windows, dynamic(false), fn window, acc ->
      currency = window.currency
      start_utc = window.start_utc
      end_utc = window.end_utc

      dynamic(
        [oi, o],
        ^acc or
          (o.currency == ^currency and
             ^start_utc <= fragment("COALESCE(?, ?)", o.paid_at, o.completed_at) and
             fragment("COALESCE(?, ?)", o.paid_at, o.completed_at) < ^end_utc)
      )
    end)
  end

  defp refund_window_filter(windows) do
    Enum.reduce(windows, dynamic(false), fn window, acc ->
      currency = window.currency
      start_utc = window.start_utc
      end_utc = window.end_utc

      dynamic(
        [_rl, r, _o, _parent],
        ^acc or
          (r.currency == ^currency and ^start_utc <= r.source_created_at and
             r.source_created_at < ^end_utc)
      )
    end)
  end

  defp fact_window_filter(windows) do
    Enum.reduce(windows, dynamic(false), fn window, acc ->
      currency = window.currency
      start_utc = window.start_utc
      end_utc = window.end_utc

      dynamic(
        [fact],
        ^acc or
          (fact.currency == ^currency and ^start_utc <= fact.effective_at and
             fact.effective_at < ^end_utc)
      )
    end)
  end

  defp source_watermark(rows) do
    rows
    |> Enum.map(& &1.source_watermark_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case utc_datetime(value) do
        {:ok, datetime} -> {:cont, {:ok, [datetime | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, values} -> {:ok, Enum.max_by(values, &DateTime.to_unix(&1, :microsecond))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refreshed_at(opts) do
    opts
    |> Keyword.get_lazy(:refreshed_at, &DateTime.utc_now/0)
    |> DateTime.truncate(:microsecond)
  end

  defp reverse_ok({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp reverse_ok({:error, _reason} = error), do: error

  defp uuid_from_repo(nil), do: {:error, :invalid_contribution_identity}

  defp uuid_from_repo(id) when is_binary(id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :invalid_contribution_identity}
        end
    end
  end

  defp uuid_from_repo(_id), do: {:error, :invalid_contribution_identity}

  defp identity_matches(repo_id, expected_id, mismatch_reason) do
    case uuid_from_repo(repo_id) do
      {:ok, ^expected_id} -> :ok
      _other -> {:error, mismatch_reason}
    end
  end

  defp contribution_kind("sale"), do: {:ok, :sale}
  defp contribution_kind("refund"), do: {:ok, :refund}
  defp contribution_kind(_kind), do: {:error, :invalid_contribution_kind}

  defp valid_currency(currency) when is_binary(currency) and byte_size(currency) > 0, do: :ok
  defp valid_currency(_currency), do: {:error, :invalid_contribution_identity}

  defp valid_product_identity(product_id, variation_id) do
    if is_integer(product_id) and product_id > 0 and
         (is_nil(variation_id) or (is_integer(variation_id) and variation_id > 0)) do
      :ok
    else
      {:error, :invalid_contribution_identity}
    end
  end

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = datetime) do
    case DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, canonical_utc} -> {:ok, canonical_utc}
      {:error, _reason} -> {:error, :invalid_contribution_effective_time}
    end
  end

  defp utc_datetime(%NaiveDateTime{} = datetime) do
    case DateTime.from_naive(datetime, "Etc/UTC") do
      {:ok, canonical_utc} -> {:ok, canonical_utc}
      {:error, _reason} -> {:error, :invalid_contribution_effective_time}
    end
  end

  defp utc_datetime(_datetime), do: {:error, :invalid_contribution_effective_time}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_event_id}
    end
  end
end
