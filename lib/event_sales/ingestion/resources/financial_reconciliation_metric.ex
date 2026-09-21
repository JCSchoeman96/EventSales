defmodule EventSales.Ingestion.Resources.FinancialReconciliationMetric do
  @moduledoc """
  Durable exact C17 comparison row for one financial reconciliation run.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  alias EventSales.Ingestion.Validations.AuthorizedFinancialReconciliationStateMutation
  alias EventSales.Sales.FinancialPrimitives

  @numeric_mismatch_categories [
    :gross_quantity_mismatch,
    :gross_value_mismatch,
    :refund_quantity_mismatch,
    :refund_value_mismatch,
    :net_quantity_mismatch,
    :net_value_mismatch
  ]

  @primitive_mismatch_categories %{
    gross_ticket_quantity: :gross_quantity_mismatch,
    gross_ticket_value: :gross_value_mismatch,
    refund_ticket_quantity: :refund_quantity_mismatch,
    refund_ticket_value: :refund_value_mismatch,
    net_ticket_quantity: :net_quantity_mismatch,
    net_ticket_value: :net_value_mismatch
  }

  @primitive_check_sql "primitive IN (#{Enum.map_join(FinancialPrimitives.primitives(), ", ", &"'#{&1}'")})"

  @mismatch_category_check_sql """
  (
    ("matched?" = true AND mismatch_category IS NULL)
    OR
    ("matched?" = false AND mismatch_category = CASE primitive
      WHEN 'gross_ticket_quantity' THEN 'gross_quantity_mismatch'
      WHEN 'gross_ticket_value' THEN 'gross_value_mismatch'
      WHEN 'refund_ticket_quantity' THEN 'refund_quantity_mismatch'
      WHEN 'refund_ticket_value' THEN 'refund_value_mismatch'
      WHEN 'net_ticket_quantity' THEN 'net_quantity_mismatch'
      WHEN 'net_ticket_value' THEN 'net_value_mismatch'
    END)
  )
  """

  @quantity_integral_check_sql """
  (
    primitive NOT IN ('gross_ticket_quantity', 'refund_ticket_quantity', 'net_ticket_quantity')
    OR (
      source_value = trunc(source_value)
      AND local_value = trunc(local_value)
      AND delta = trunc(delta)
    )
  )
  """

  @persist_accept [
    :financial_reconciliation_run_id,
    :currency,
    :primitive,
    :source_value,
    :local_value,
    :delta,
    :matched?,
    :mismatch_category
  ]

  postgres do
    table "ingestion_financial_reconciliation_metrics"
    repo EventSales.Repo

    references do
      reference :financial_reconciliation_run, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :financial_reconciliation_run_id,
        name: "ingestion_fin_recon_metrics_run_id_idx"
    end

    identity_index_names unique_run_currency_primitive: "ingestion_fin_recon_metrics_identity_idx"

    check_constraints do
      check_constraint :currency,
        name: "ingestion_fin_recon_metrics_currency_check",
        check: "btrim(currency) <> ''"

      check_constraint :primitive,
        name: "ingestion_fin_recon_metrics_primitive_check",
        check: @primitive_check_sql

      check_constraint :delta,
        name: "ingestion_fin_recon_metrics_delta_check",
        check: "delta = local_value - source_value"

      check_constraint :matched?,
        name: "ingestion_fin_recon_metrics_matched_check",
        check: "\"matched?\" = (source_value = local_value)"

      check_constraint :mismatch_category,
        name: "ingestion_fin_recon_metrics_mismatch_category_check",
        check: @mismatch_category_check_sql

      check_constraint :source_value,
        name: "ingestion_fin_recon_metrics_quantity_integral_check",
        check: @quantity_integral_check_sql
    end
  end

  actions do
    defaults [:read]

    create :persist do
      accept @persist_accept
      validate {AuthorizedFinancialReconciliationStateMutation, []}

      validate present([
                 :financial_reconciliation_run_id,
                 :currency,
                 :primitive,
                 :source_value,
                 :local_value,
                 :delta,
                 :matched?
               ])

      validate &__MODULE__.validate_primitive/2
      validate &__MODULE__.validate_currency/2
      validate &__MODULE__.validate_arithmetic/2
      validate &__MODULE__.validate_match_flag/2
      validate &__MODULE__.validate_quantity_integral/2
      validate &__MODULE__.validate_mismatch_category/2
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :currency, :string do
      allow_nil? false
      public? true
    end

    attribute :primitive, :atom do
      allow_nil? false
      constraints one_of: FinancialPrimitives.primitives()
      public? true
    end

    attribute :source_value, :decimal do
      allow_nil? false
      public? true
    end

    attribute :local_value, :decimal do
      allow_nil? false
      public? true
    end

    attribute :delta, :decimal do
      allow_nil? false
      public? true
    end

    attribute :matched?, :boolean do
      allow_nil? false
      public? true
    end

    attribute :mismatch_category, :atom do
      constraints one_of: [nil | @numeric_mismatch_categories]
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :financial_reconciliation_run,
               EventSales.Ingestion.Resources.FinancialReconciliationRun do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_run_currency_primitive, [
      :financial_reconciliation_run_id,
      :currency,
      :primitive
    ]
  end

  def validate_primitive(changeset, _context) do
    primitive = Ash.Changeset.get_attribute(changeset, :primitive)

    if primitive in FinancialPrimitives.primitives() do
      :ok
    else
      {:error, field: :primitive, message: "unknown financial primitive"}
    end
  end

  def validate_currency(changeset, _context) do
    currency = Ash.Changeset.get_attribute(changeset, :currency)

    if is_binary(currency) and currency != "" do
      :ok
    else
      {:error, field: :currency, message: "must be a non-empty currency code"}
    end
  end

  def validate_arithmetic(changeset, _context) do
    source_value = Ash.Changeset.get_attribute(changeset, :source_value)
    local_value = Ash.Changeset.get_attribute(changeset, :local_value)
    delta = Ash.Changeset.get_attribute(changeset, :delta)

    expected = Decimal.sub(local_value, source_value)

    if Decimal.equal?(delta, expected) do
      :ok
    else
      {:error, field: :delta, message: "must equal local_value minus source_value"}
    end
  end

  def validate_match_flag(changeset, _context) do
    source_value = Ash.Changeset.get_attribute(changeset, :source_value)
    local_value = Ash.Changeset.get_attribute(changeset, :local_value)
    matched? = Ash.Changeset.get_attribute(changeset, :matched?)

    if matched? == Decimal.equal?(source_value, local_value) do
      :ok
    else
      {:error, field: :matched?, message: "must equal Decimal.equal?(source_value, local_value)"}
    end
  end

  def validate_quantity_integral(changeset, _context) do
    primitive = Ash.Changeset.get_attribute(changeset, :primitive)

    if FinancialPrimitives.quantity_primitive?(primitive) do
      source_value = Ash.Changeset.get_attribute(changeset, :source_value)
      local_value = Ash.Changeset.get_attribute(changeset, :local_value)
      delta = Ash.Changeset.get_attribute(changeset, :delta)

      cond do
        not integral_quantity?(source_value) ->
          {:error, field: :source_value, message: "quantity primitive must be integral"}

        not integral_quantity?(local_value) ->
          {:error, field: :local_value, message: "quantity primitive must be integral"}

        not integral_quantity?(delta) ->
          {:error, field: :delta, message: "quantity primitive delta must be integral"}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  def validate_mismatch_category(changeset, _context) do
    primitive = Ash.Changeset.get_attribute(changeset, :primitive)
    matched? = Ash.Changeset.get_attribute(changeset, :matched?)
    mismatch_category = Ash.Changeset.get_attribute(changeset, :mismatch_category)
    expected = Map.get(@primitive_mismatch_categories, primitive)

    cond do
      matched? and not is_nil(mismatch_category) ->
        {:error, field: :mismatch_category, message: "must be nil when matched"}

      not matched? and mismatch_category != expected ->
        {:error, field: :mismatch_category, message: "must match M4-04 category for primitive"}

      true ->
        :ok
    end
  end

  defp integral_quantity?(%Decimal{} = value) do
    Decimal.equal?(Decimal.rem(value, 1), Decimal.new(0))
  end

  defp integral_quantity?(_value), do: false
end
